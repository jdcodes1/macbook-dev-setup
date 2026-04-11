#!/usr/bin/env bash

# Development Environment Setup Script
# Simplified interface with smart defaults
# For macOS Apple Silicon

VERSION="3.5.0"

# Check bash version (requires bash 4+ for features like indirect expansion)
check_bash_version() {
    local bash_major_version="${BASH_VERSION%%.*}"
    if [[ "$bash_major_version" -lt 4 ]]; then
        echo "Warning: You're using bash $BASH_VERSION"
        echo "This script requires bash 4.0 or higher for full functionality."
        echo ""
        echo "Your system bash (/bin/bash) is version 3.2.57"
        if command -v brew &>/dev/null && brew list bash &>/dev/null; then
            echo "Homebrew bash is installed. Please ensure /opt/homebrew/bin is in your PATH."
        else
            echo "Install modern bash with: brew install bash"
        fi
        echo ""
        echo "Current bash: $(which bash)"
        echo "Continuing anyway, but some features may not work correctly..."
        echo ""
    fi
}

# Check bash version early
check_bash_version

# Load common library
source "$(dirname "$0")/lib/common.sh"

# Load UI presentation layer
source "$(dirname "$0")/lib/ui.sh"

# Load backup manager
source "$(dirname "$0")/lib/backup-manager.sh"

# Load OS auto-fix library
source "$(dirname "$0")/lib/os-auto-fix.sh"

# Load profile-based Brewfile filtering
source "$(dirname "$0")/lib/profiles.sh"

# Environment variables for power users
VERBOSE="${SETUP_VERBOSE:-false}"
LOG_FILE="${SETUP_LOG:-}"
PARALLEL_JOBS="${SETUP_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# Script start time for performance tracking
SCRIPT_START_TIME=$(date +%s)

# Simple help message
show_help() {
    cat << EOF
Development Environment Setup - Simple & Smart

Usage: ./setup.sh [command]

Commands:
    (none)     Smart setup - detects what needs to be done
    preview    Show what would be installed/updated
    minimal    Install essential tools only
    fix        Run diagnostics and fix common issues
    warp       Configure Warp terminal optimizations
    backup     Manage setup backups
    info       Learn about installed tools, aliases & features
    advanced   Interactive mode for advanced options
    new-extension <name> [dir]  Scaffold a new extension pack
    help       Show this help message

Options:
    --profile NAME          Use a profile to filter packages (e.g., work, personal)
                            Profiles live in homebrew/profiles/<name>.conf
    --list-profiles         List available profiles
    --validate-profile NAME Validate a profile config for errors

Examples:
    ./setup.sh                      # First run: full setup. Later: sync & update
    ./setup.sh preview              # See what would happen
    ./setup.sh minimal              # Quick essential setup
    ./setup.sh --profile work       # Setup with work profile (excludes GenAI tools)

For power users - use environment variables:
    SETUP_VERBOSE=1 ./setup.sh      # Verbose output
    SETUP_JOBS=8 ./setup.sh         # Custom parallel jobs
    SETUP_LOG=file.log ./setup.sh   # Log to file
    SETUP_DIFF_STYLE=unified ./setup.sh  # Diff style: diff-so-fancy|side-by-side|unified|color-only

EOF
}

# Smart detection of what needs to be done
detect_setup_state() {
    local state="fresh"
    
    # Check if this is a fresh install or update
    if command -v brew &> /dev/null; then
        state="update"
    fi
    
    if [[ -f "$HOME/.zshrc" ]] && grep -q "macbook-dev-setup" "$HOME/.zshrc" 2>/dev/null; then
        state="update"
    fi
    
    echo "$state"
}

# Check for Warp and offer optimization
check_and_setup_warp() {
    # Skip if explicitly disabled
    if [[ "${SETUP_NO_WARP:-false}" == "true" ]]; then
        return 0
    fi
    
    # Check if Warp is installed or being used
    local warp_detected=false
    local warp_reason=""
    
    if [[ "$TERM_PROGRAM" == "WarpTerminal" ]]; then
        warp_detected=true
        warp_reason="currently using Warp Terminal"
    elif [[ -d "/Applications/Warp.app" ]]; then
        warp_detected=true
        warp_reason="Warp.app installed"
    elif command -v warp &> /dev/null; then
        warp_detected=true
        warp_reason="Warp command found"
    fi
    
    # If Warp detected and optimizations not already installed
    if [[ "$warp_detected" == true ]] && [[ ! -f "$HOME/.config/zsh/45-warp.zsh" ]]; then
        echo ""
        print_info "Warp Terminal detected ($warp_reason)"
        echo ""
        echo "Warp offers enhanced features that work great with your setup:"
        echo "• AI-powered command suggestions"
        echo "• Beautiful command blocks and workflows"
        echo "• Smart history search and sharing"
        echo ""
        
        if confirm "Would you like to optimize your setup for Warp?" "y"; then
            if [[ -f "scripts/setup-warp.sh" ]]; then
                echo ""
                ./scripts/setup-warp.sh --auto
            else
                print_warning "Warp setup script not found"
            fi
        else
            echo ""
            echo "You can run './setup.sh warp' later to add Warp optimizations"
        fi
    elif [[ "$warp_detected" == true ]] && [[ -f "$HOME/.config/zsh/45-warp.zsh" ]]; then
        print_success "Warp optimizations already configured"
    fi
}

# Interactive advanced options menu
show_advanced_menu() {
    local menu_options=(
        "Use custom configuration file"
        "Set parallel jobs (current: $PARALLEL_JOBS)"
        "Skip creating backups"
        "Enable verbose logging"
        "Select installation profile"
        "Show current configuration"
        "Return to main setup"
    )

    local choice
    choice=$(ui_choose "Advanced Setup Options:" "${menu_options[@]}") || return 0

    case "$choice" in
        "Use custom configuration file")
            read -r -p "Enter configuration file path: " config_file
            if [[ -f "$config_file" ]]; then
                export SETUP_CONFIG="$config_file"
                print_success "Using configuration: $config_file"
            else
                print_error "Configuration file not found: $config_file"
            fi
            show_advanced_menu
            ;;
        "Set parallel jobs"*)
            read -r -p "Enter number of parallel jobs (1-16): " jobs
            if [[ "$jobs" =~ ^[0-9]+$ ]] && [[ "$jobs" -ge 1 ]] && [[ "$jobs" -le 16 ]]; then
                PARALLEL_JOBS="$jobs"
                print_success "Parallel jobs set to: $jobs"
            else
                print_error "Invalid number of jobs"
            fi
            show_advanced_menu
            ;;
        "Skip creating backups")
            export SETUP_NO_BACKUP=true
            print_success "Backup creation disabled"
            show_advanced_menu
            ;;
        "Enable verbose logging")
            VERBOSE=true
            print_success "Verbose logging enabled"
            show_advanced_menu
            ;;
        "Select installation profile")
            # Dynamically discover profiles from homebrew/profiles/*.conf
            local profile_opts=()
            for conf in homebrew/profiles/*.conf; do
                [[ -f "$conf" ]] || continue
                local pname
                pname=$(basename "$conf" .conf)
                # Read first comment line as description
                local pdesc
                pdesc=$(grep -m1 '^#' "$conf" | sed 's/^# *//' || echo "$pname")
                profile_opts+=("${pname} — ${pdesc}")
            done
            if [[ ${#profile_opts[@]} -eq 0 ]]; then
                print_warning "No profiles found in homebrew/profiles/"
            else
                local selected
                selected=$(ui_choose "Select installation profile:" "${profile_opts[@]}") || true
                if [[ -n "$selected" ]]; then
                    # Extract profile name (before the " — ")
                    export SETUP_PROFILE="${selected%% —*}"
                    print_success "Profile set to: $SETUP_PROFILE"
                fi
            fi
            show_advanced_menu
            ;;
        "Show current configuration")
            ui_summary_box "Current Configuration" \
                "Parallel Jobs: $PARALLEL_JOBS" \
                "Verbose: $VERBOSE" \
                "Log File: ${LOG_FILE:-none}" \
                "Profile: ${SETUP_PROFILE:-default}" \
                "Config File: ${SETUP_CONFIG:-default}" \
                "No Backup: ${SETUP_NO_BACKUP:-false}"
            read -r -p "Press Enter to continue..."
            show_advanced_menu
            ;;
        "Return to main setup")
            return 0
            ;;
        *)
            print_error "Invalid option"
            show_advanced_menu
            ;;
    esac
}

# Run diagnostics and fix common issues
run_diagnostics() {
    echo ""
    ui_section_header "Running Diagnostics"
    
    local issues_found=0
    
    # Check Xcode Command Line Tools
    if ! xcode-select -p &>/dev/null; then
        print_warning "Xcode Command Line Tools not installed"
        if confirm "Install Xcode Command Line Tools?" "y"; then
            xcode-select --install
            print_info "Please complete the installation and run setup again"
            exit 0
        fi
        ((issues_found++))
    else
        print_success "Xcode Command Line Tools: OK"
    fi
    
    # Check Homebrew
    if command -v brew &>/dev/null; then
        print_info "Running Homebrew diagnostics..."
        if ! brew doctor &>/dev/null; then
            print_warning "Homebrew has issues"
            if confirm "Run 'brew doctor' to see details?" "y"; then
                brew doctor
            fi
            ((issues_found++))
        else
            print_success "Homebrew: OK"
        fi
    else
        print_warning "Homebrew not installed"
        ((issues_found++))
    fi
    
    # Check shell configuration
    if [[ ! -f "$HOME/.zshrc" ]]; then
        print_warning "No .zshrc file found"
        ((issues_found++))
    else
        print_success "Shell configuration: OK"
    fi
    
    # Check disk space
    local free_space_gb=$(df -g / | awk 'NR==2 {print $4}')
    if [[ $free_space_gb -lt 5 ]]; then
        print_warning "Low disk space: ${free_space_gb}GB free (recommended: 5GB+)"
        ((issues_found++))
    else
        print_success "Disk space: ${free_space_gb}GB free"
    fi
    
    # Summary
    echo ""
    if [[ $issues_found -eq 0 ]]; then
        print_success "No issues found! Your system is ready."
    else
        print_warning "Found $issues_found issue(s)"
        if confirm "Would you like to run setup to fix these issues?" "y"; then
            main_setup
        fi
    fi
}

# Main setup function
main_setup() {
    local setup_state=$(detect_setup_state)
    local is_minimal="${1:-false}"
    
    # Initialize logging if specified
    if [[ -n "$LOG_FILE" ]]; then
        echo "Setup started at $(date)" > "$LOG_FILE"
        print_info "Logging to: $LOG_FILE"
    fi

    # Initialize deferred error reporting
    setup_errors_init
    
    # Show what we're doing
    if [[ "$setup_state" == "fresh" ]]; then
        ui_section_header "Fresh Installation Detected"
    else
        ui_section_header "Update & Sync Mode"
    fi
    
    # Create restore point unless disabled
    if [[ "${SETUP_NO_BACKUP:-false}" != "true" ]]; then
        print_step "Creating restore point..."
        
        # Create organized restore point
        local restore_point=$(create_backup "restore-points" "$HOME" "Setup restore point")
        
        # Backup key files to restore point
        for file in .zshrc .gitconfig .config/nvim .bashrc .bash_profile; do
            if [[ -e "$HOME/$file" ]]; then
                if [[ -d "$HOME/$file" ]]; then
                    cp -r "$HOME/$file" "$restore_point/" 2>/dev/null || true
                else
                    cp "$HOME/$file" "$restore_point/" 2>/dev/null || true
                fi
            fi
        done
        
        # Save current package states
        if command -v brew &>/dev/null; then
            brew list > "$restore_point/brew-packages.txt" 2>/dev/null || true
            brew list --cask > "$restore_point/brew-casks.txt" 2>/dev/null || true
        fi
        
        print_success "Restore point created: $restore_point"
        export RESTORE_POINT="$restore_point"
    fi
    
    # Run prerequisites check and auto-fix
    print_step "Checking prerequisites..."
    
    # Run pre-flight checks and auto-fixes
    if ! preflight_check; then
        print_error "Pre-flight checks failed. Please fix the issues above and try again."
        exit 1
    fi
    
    # Auto-fix common issues before proceeding
    run_auto_fixes "$(dirname "$0")"
    local auto_fix_result=$?
    
    if [[ $auto_fix_result -eq 2 ]]; then
        # Manual intervention needed
        exit 1
    fi
    
    # Basic prerequisite checks inline since lib files may not exist
    if ! xcode-select -p &>/dev/null; then
        print_error "Xcode Command Line Tools not installed"
        echo "Please run: xcode-select --install"
        exit 1
    fi
    
    # Discover extension packs and merge their profiles BEFORE package install
    discover_extensions
    if [[ ${#EXTENSION_PACKS[@]} -gt 0 ]]; then
        ui_section_header "Extension Packs"
        print_extensions_summary
        for _ext_pack_dir in "${EXTENSION_PACKS[@]}"; do
            load_extension_profile "$_ext_pack_dir"
        done
    fi

    # Install or update based on state
    if [[ "$setup_state" == "fresh" ]]; then
        # Fresh installation
        phase_start
        ui_spinner "Installing Homebrew" ./scripts/install-homebrew.sh
        phase_end "Homebrew"

        print_step "Installing packages..."
        phase_start
        if [[ "$is_minimal" == "true" ]]; then
            ui_spinner "Installing packages (minimal)" env BREWFILE="homebrew/Brewfile.minimal" ./scripts/install-packages.sh
            phase_end "Packages" "minimal"
        elif [[ -n "$SETUP_PROFILE" ]]; then
            if ! resolve_profile "$SETUP_PROFILE"; then
                exit 1
            fi
            print_profile_summary "$SETUP_PROFILE"
            ui_spinner "Installing packages (profile: $SETUP_PROFILE)" env BREWFILE=$(filter_brewfile "homebrew/Brewfile") ./scripts/install-packages.sh
            phase_end "Packages" "profile: $SETUP_PROFILE"
        else
            ui_spinner "Installing packages" ./scripts/install-packages.sh
            phase_end "Packages"
        fi

        # Not wrapped in spinner — needs user interaction for email/org prompts
        print_step "Setting up dotfiles..."
        phase_start
        ./scripts/setup-dotfiles.sh
        phase_end "Dotfiles"

        # Not wrapped in spinner — needs user interaction for diff review
        print_step "Setting up global Claude configuration..."
        phase_start
        ./scripts/setup-claude-global.sh
        phase_end "Claude global config"

        phase_start
        if [[ "${PROFILE_SKIP_AGENTIC:-false}" != "true" ]]; then
            print_step "Setting up Claude agentic workflow..."
            if command -v claude &>/dev/null; then
                [[ ! -x "./scripts/setup-claude-agentic.sh" ]] && chmod +x "./scripts/setup-claude-agentic.sh"
                ./scripts/setup-claude-agentic.sh
            else
                print_info "Claude Code CLI not found - skipping agentic setup"
            fi
        else
            print_info "Skipping agentic setup (profile: $SETUP_PROFILE)"
        fi
        phase_end "Claude agentic setup"

        phase_start
        ui_spinner "Configuring applications" ./scripts/setup-applications.sh
        phase_end "Applications"

        phase_start
        ui_spinner "Configuring terminal fonts" ./scripts/setup-terminal-fonts.sh
        phase_end "Terminal fonts"

        phase_start
        ui_spinner "Configuring macOS settings" ./scripts/setup-macos.sh
        phase_end "macOS settings"
        
    else
        # Update existing installation
        ui_section_header "Package Sync"
        phase_start
        if command -v brew &>/dev/null; then
            ui_spinner "Updating Homebrew" brew update
            if [[ "$is_minimal" == "true" ]] && [[ -f "homebrew/Brewfile.minimal" ]]; then
                ui_spinner_tolerant "Syncing packages (minimal)" brew bundle --file="homebrew/Brewfile.minimal"
            elif [[ -n "$SETUP_PROFILE" ]]; then
                if ! resolve_profile "$SETUP_PROFILE"; then
                    exit 1
                fi
                print_profile_summary "$SETUP_PROFILE"
                local filtered_brewfile
                filtered_brewfile=$(filter_brewfile "homebrew/Brewfile")
                ui_spinner_tolerant "Syncing packages (profile: $SETUP_PROFILE)" brew bundle --file="$filtered_brewfile"
            else
                ui_spinner_tolerant "Syncing packages" brew bundle --file="homebrew/Brewfile"
            fi
            # Install machine-specific packages if present
            if [[ -f "homebrew/Brewfile.local" ]]; then
                ui_spinner_tolerant "Syncing local packages" brew bundle --file="homebrew/Brewfile.local"
            fi
        fi
        phase_end "Package sync"

        ui_section_header "Package Updates"
        phase_start
        if command -v brew &>/dev/null; then
            # Check what needs updating — output kept visible (user needs the list)
            local outdated_packages=$(brew outdated -q 2>/dev/null)

            if [[ -n "$outdated_packages" ]]; then
                local package_count=$(echo "$outdated_packages" | wc -l | tr -d ' ')
                print_info "Found $package_count outdated packages"
                echo "$outdated_packages" | head -10
                if [[ $package_count -gt 10 ]]; then
                    echo "... and $((package_count - 10)) more"
                fi

                ui_spinner "Upgrading $package_count packages" brew upgrade -q
                print_success "Updated $package_count packages"
            else
                print_info "All packages are up to date"
            fi

            # Cleanup old versions
            local cleanup_size=$(brew cleanup -n 2>/dev/null | grep "Would remove" | sed 's/.*Would remove: //' || echo "0B")
            if [[ "$cleanup_size" != "0B" ]]; then
                ui_spinner "Cleaning up old versions" brew cleanup -q
            fi
        fi
        phase_end "Package updates"

        ui_section_header "Configuration Sync"
        phase_start
        # Not wrapped in spinner — needs user interaction for diff review
        if [[ -f "./scripts/setup-dotfiles.sh" ]]; then
            print_step "Updating dotfiles..."
            ./scripts/setup-dotfiles.sh --update
        fi

        # Not wrapped in spinner — needs user interaction for diff review
        if [[ -f "./scripts/setup-claude-global.sh" ]]; then
            print_step "Updating global Claude configuration..."
            ./scripts/setup-claude-global.sh
        fi

        if [[ "${PROFILE_SKIP_AGENTIC:-false}" != "true" ]]; then
            print_step "Setting up Claude agentic workflow..."
            if command -v claude &>/dev/null; then
                [[ ! -x "./scripts/setup-claude-agentic.sh" ]] && chmod +x "./scripts/setup-claude-agentic.sh"
                ./scripts/setup-claude-agentic.sh
            else
                print_info "Claude Code CLI not found - skipping agentic setup"
            fi
        else
            print_info "Skipping agentic setup (profile: $SETUP_PROFILE)"
        fi
        phase_end "Configuration sync"
    fi
    
    # Run extension pack scripts (profiles were already loaded before package install)
    if [[ ${#EXTENSION_PACKS[@]} -gt 0 ]]; then
        ui_section_header "Extension Pack Scripts"
        for _ext_pack_dir in "${EXTENSION_PACKS[@]}"; do
            local _ext_name
            _ext_name=$(basename "$_ext_pack_dir")

            if [[ -d "${_ext_pack_dir}scripts" ]]; then
                for _ext_script in "${_ext_pack_dir}scripts"/*.sh; do
                    [[ ! -f "$_ext_script" ]] && continue
                    print_step "Running extension script: $_ext_name/$(basename "$_ext_script")"
                    if ! bash "$_ext_script"; then
                        setup_errors_add "Extension script failed: $_ext_name/$(basename "$_ext_script")"
                    fi
                done
            fi
        done
    fi

    # Check for Warp and offer optimization
    check_and_setup_warp

    # Show completion message
    local duration=$(($(date +%s) - SCRIPT_START_TIME))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))

    local summary_lines=()
    summary_lines+=("Mode: ${setup_state}")
    summary_lines+=("Time: ${minutes}m ${seconds}s")
    [[ -n "${SETUP_PROFILE:-}" ]] && summary_lines+=("Profile: ${SETUP_PROFILE}")
    [[ "$is_minimal" == "true" ]] && summary_lines+=("Profile: minimal")
    [[ ${#EXTENSION_PACKS[@]} -gt 0 ]] && summary_lines+=("Extensions: ${#EXTENSION_PACKS[@]} loaded")

    # Show MCP server status if available
    if command -v claude &>/dev/null; then
        local mcp_status
        mcp_status=$(claude mcp list 2>/dev/null | grep -cE "✓ Connected" || true)
        summary_lines+=("MCP Servers: ${mcp_status} connected")
    fi

    # Show any deferred errors before the summary
    setup_errors_show

    # Show timing breakdown
    phase_summary

    ui_summary_box "Setup Complete!" "${summary_lines[@]}"

    if [[ "$setup_state" == "fresh" ]]; then
        echo ""
        echo -e "${YELLOW}⚠️  IMPORTANT: Restart your terminal to apply changes${NC}"
        echo ""
        echo "Next steps:"
        echo "• Open a new terminal window"
        echo "• Run 'claude mcp list' to verify MCP servers are connected"
    elif [[ "${AUTOFIX_NEEDS_RELOAD:-false}" == "true" ]]; then
        echo ""
        print_info "Auto-fixes were applied. Restart your terminal or run 'source ~/.zshrc' for changes to take effect."
    fi
}

# Pre-parse --profile flag from arguments
export SETUP_PROFILE=""
REMAINING_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            if [[ -n "${2:-}" ]]; then
                SETUP_PROFILE="$2"
                shift 2
            else
                print_error "--profile requires a profile name"
                exit 1
            fi
            ;;
        --list-profiles)
            list_profiles
            exit 0
            ;;
        --validate-profile)
            if [[ -n "${2:-}" ]]; then
                if validate_profile "$2"; then
                    print_success "Profile '$2' is valid"
                fi
                exit $?
            else
                print_error "--validate-profile requires a profile name"
                exit 1
            fi
            ;;
        *)
            REMAINING_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${REMAINING_ARGS[@]}"

# Main script logic
case "${1:-}" in
    "help"|"-h"|"--help")
        show_help
        ;;
    
    "preview")
        print_info "Running in preview mode..."
        if [[ -f "setup-validate.sh" ]]; then
            ./setup-validate.sh
        else
            DRY_RUN=true main_setup
        fi
        ;;
    
    "minimal")
        print_info "Running minimal setup..."
        main_setup true
        ;;
    
    "fix")
        ui_section_header "Running Comprehensive Diagnostics & Auto-Fix"
        
        # First run auto-fixes
        run_auto_fixes "$(dirname "$0")"
        fix_result=$?
        
        # Then run additional diagnostics
        if [[ $fix_result -ne 2 ]]; then
            # Only run diagnostics if we don't need manual intervention
            run_diagnostics
        fi
        ;;
    
    "warp")
        if [[ -f "scripts/setup-warp.sh" ]]; then
            ./scripts/setup-warp.sh
        else
            print_error "Warp setup script not found"
            print_info "Creating Warp setup script..."
            # This would be created in the next step
        fi
        ;;
    
    "backup")
        # Backup management subcommands
        case "${2:-list}" in
            "list")
                list_backups
                ;;
            "migrate")
                print_info "Migrating old backups to organized structure..."
                migrate_old_backups
                ;;
            "clean")
                print_info "Cleaning old backups..."
                for category in "${BACKUP_CATEGORIES[@]}"; do
                    clean_old_backups "$category"
                done
                print_success "Backup cleanup complete"
                ;;
            *)
                echo "Usage: ./setup.sh backup [list|clean]"
                echo "  list    - List all backups (default)"
                echo "  clean   - Remove old backups exceeding limit"
                echo ""
                echo "Note: Backups are created automatically during setup"
                ;;
        esac
        ;;
    
    "info")
        # Run the help script with any additional arguments
        if [[ -f "scripts/setup-help.sh" ]]; then
            ./scripts/setup-help.sh "$2" "$3"
        else
            print_error "Info script not found at scripts/setup-help.sh"
            exit 1
        fi
        ;;
    
    "advanced")
        show_advanced_menu
        main_setup
        ;;
    
    "new-extension")
        shift
        "$ROOT_DIR/scripts/scaffold-extension.sh" "$@"
        ;;

    "")
        # Default: smart setup
        main_setup
        ;;

    *)
        print_error "Unknown command: $1"
        echo "Run './setup.sh help' for usage"
        exit 1
        ;;
esac