#!/usr/bin/env bash

# Install packages from Brewfile with error handling
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

# Check if Homebrew is installed
if ! command -v brew &> /dev/null; then
    print_error "Homebrew is not installed. Please run install-homebrew.sh first."
    exit 1
fi

# Check if Brewfile exists
BREWFILE="${BREWFILE:-homebrew/Brewfile}"
if [[ ! -f "$BREWFILE" ]]; then
    print_error "Brewfile not found at $BREWFILE"
    exit 1
fi

echo "Installing packages from Brewfile..."

# Pre-fetch installed package lists (single call each, ~200ms total vs ~10s for per-package checks)
echo "Checking installed packages..."
INSTALLED_FORMULAE=$(brew list --formula -1 2>/dev/null)
INSTALLED_CASKS=$(brew list --cask -1 2>/dev/null)

is_formula_installed() {
    echo "$INSTALLED_FORMULAE" | grep -qx "$1"
}

is_cask_installed() {
    echo "$INSTALLED_CASKS" | grep -qx "$1"
}

# Parse and install packages with better error handling
install_packages() {
    local failed_packages=()
    local skipped_fonts=()
    
    # Process taps first
    while IFS= read -r line; do
        if [[ "$line" =~ ^tap[[:space:]]+"(.+)" ]]; then
            local tap="${BASH_REMATCH[1]}"
            echo "Tapping $tap..."
            if ! brew tap "$tap" 2>/dev/null; then
                print_warning "Failed to tap $tap"
            fi
        fi
    done < "$BREWFILE"
    
    # Process formulae
    while IFS= read -r line; do
        if [[ "$line" =~ ^brew[[:space:]]+"(.+)" ]]; then
            local formula="${BASH_REMATCH[1]}"
            if is_formula_installed "$formula"; then
                echo "Formula $formula already installed, skipping..."
            else
                echo "Installing formula: $formula"
                if ! HOMEBREW_NO_AUTO_UPDATE=1 brew install "$formula" 2>/dev/null; then
                    # Check if it might be a cask instead
                    if brew info --cask "$formula" &>/dev/null; then
                        print_warning "$formula appears to be a cask, not a formula. Consider updating Brewfile."
                        failed_packages+=("brew \"$formula\" # Should be: cask \"$formula\"")
                    else
                        print_warning "Failed to install formula: $formula"
                        failed_packages+=("brew \"$formula\"")
                    fi
                fi
            fi
        fi
    done < "$BREWFILE"
    
    # Process casks
    while IFS= read -r line; do
        if [[ "$line" =~ ^cask[[:space:]]+"(.+)" ]]; then
            local cask="${BASH_REMATCH[1]}"
            # Special handling for fonts
            if [[ "$cask" =~ ^font- ]]; then
                if is_cask_installed "$cask"; then
                    echo "Font $cask already installed, skipping..."
                    skipped_fonts+=("$cask")
                    continue
                fi
                
                # Check if font files exist even if not installed via Homebrew
                local font_pattern=""
                case "$cask" in
                    "font-anonymice-nerd-font")
                        font_pattern="AnonymiceProNerdFont"
                        ;;
                    "font-symbols-only-nerd-font")
                        font_pattern="SymbolsNerdFont"
                        ;;
                esac
                
                if [[ -n "$font_pattern" ]] && ls ~/Library/Fonts/*${font_pattern}* &>/dev/null 2>&1; then
                    print_warning "Font files for $cask already exist in ~/Library/Fonts/"
                    print_info "Skipping to avoid conflicts. To reinstall, remove existing font files first."
                    skipped_fonts+=("$cask (existing files)")
                    continue
                fi
            elif is_cask_installed "$cask"; then
                echo "Cask $cask already installed, skipping..."
                continue
            fi
            
            echo "Installing cask: $cask"
            if ! HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask "$cask" 2>/dev/null; then
                print_warning "Failed to install cask: $cask"
                failed_packages+=("cask \"$cask\"")
            fi
        fi
    done < "$BREWFILE"
    
    # Report results
    if [[ ${#skipped_fonts[@]} -gt 0 ]]; then
        print_success "Skipped ${#skipped_fonts[@]} already installed fonts: ${skipped_fonts[*]}"
    fi
    
    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        print_error "Failed to install ${#failed_packages[@]} packages:"
        for pkg in "${failed_packages[@]}"; do
            echo "  - $pkg"
        done
        return 1
    else
        print_success "All packages installed successfully"
        return 0
    fi
}

# Run installation with fallback to brew bundle if custom installation fails
if ! install_packages; then
    print_warning "Custom installation encountered errors. Trying brew bundle as fallback..."
    if ! HOMEBREW_NO_AUTO_UPDATE=1 brew bundle --file="$BREWFILE"; then
        print_error "Some packages failed to install. Check the output above for details."
        exit 1
    fi
fi

# Install local overrides if present (machine-specific packages)
if [[ -f "homebrew/Brewfile.local" ]]; then
    print_success "Installing local packages from Brewfile.local..."
    HOMEBREW_NO_AUTO_UPDATE=1 brew bundle --file="homebrew/Brewfile.local" || \
        print_warning "Some local packages failed to install"
fi

# Update all packages
echo "Updating Homebrew and installed packages..."
if ! brew update; then
    print_warning "Failed to update Homebrew package list"
fi

if ! brew upgrade; then
    print_warning "Failed to upgrade some packages"
fi

# Cleanup
echo "Cleaning up old package versions..."
if ! brew cleanup; then
    print_warning "Cleanup failed, but packages are installed"
fi

print_success "Package installation and cleanup completed"
