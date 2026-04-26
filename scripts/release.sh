#!/bin/bash

# Script to create a release and bump version for next cycle
# Usage: ./scripts/release.sh [--bump major|minor|patch] [--no-bump]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
BUMP_VERSION=true  # Default to true - always bump version
BUMP_TYPE="patch"  # Default to patch bump
NON_INTERACTIVE=false  # When true, skip all read prompts and assume yes
while [[ $# -gt 0 ]]; do
    case $1 in
        --bump)
            BUMP_VERSION=true
            if [[ -n "$2" && "$2" != -* ]]; then
                BUMP_TYPE="$2"
                shift
            fi
            shift
            ;;
        --no-bump)
            BUMP_VERSION=false
            shift
            ;;
        --yes|-y)
            NON_INTERACTIVE=true
            shift
            ;;
        *)
            echo "Usage: $0 [--bump major|minor|patch] [--no-bump] [--yes|-y]"
            echo "  Default: bump patch version after release"
            echo "  Use --no-bump to skip version bump"
            echo "  Use --yes/-y to run non-interactively (assume yes for all prompts;"
            echo "  also fails fast if a step would normally need a manual decision,"
            echo "  e.g. CHANGELOG missing or homebrew-tap fetch failure)"
            exit 1
            ;;
    esac
done

# Helper: prompt unless --yes is set. In non-interactive mode, just print the
# message (so logs show what was skipped) and continue without reading stdin.
confirm_or_skip() {
    local message="$1"
    if [ "$NON_INTERACTIVE" = true ]; then
        echo "[--yes] auto-confirming: $message"
        return 0
    fi
    echo -e "${YELLOW}$message${NC}"
    read -r
}

# Helper: prompt for y/n confirmation, or auto-yes in non-interactive mode.
# Returns 0 on yes, 1 on anything else.
confirm_yn() {
    local message="$1"
    if [ "$NON_INTERACTIVE" = true ]; then
        echo "[--yes] auto-confirming: $message"
        return 0
    fi
    echo -e "${YELLOW}$message (y/n)${NC}"
    local reply
    read -r reply
    [ "$reply" = "y" ]
}

CURRENT_VERSION=$(cat VERSION)
TAG="v$CURRENT_VERSION"

# Determine total steps
if [ "$BUMP_VERSION" = true ]; then
    TOTAL_STEPS=8
else
    TOTAL_STEPS=7
fi

# Step-by-step guide
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                    Release Process for v$CURRENT_VERSION${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Steps to complete:"
echo "  1. Pre-flight checks (branch, uncommitted changes, tag exists)"
echo "  2. Pull latest changes from origin"
echo "  3. Check/update CHANGELOG.md"
echo "  4. Run tests"
echo "  5. Build release binaries"
echo "  6. Generate release notes"
echo "  7. Create and push tag"
if [ "$BUMP_VERSION" = true ]; then
echo "  8. Bump version for next development cycle"
fi
echo ""
confirm_or_skip "Press Enter to start, or Ctrl+C to cancel"
echo ""

# Step 1: Pre-flight checks
echo -e "${BLUE}[Step 1/$TOTAL_STEPS] Pre-flight checks...${NC}"

# Check if we're on main branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo -e "${RED}Error: Not on main branch. Current branch: $CURRENT_BRANCH${NC}"
    echo "Please switch to main branch before releasing"
    exit 1
fi

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo -e "${RED}Error: There are uncommitted changes${NC}"
    echo "Please commit or stash your changes before releasing"
    exit 1
fi

# Check if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo -e "${RED}Error: Tag $TAG already exists${NC}"
    echo "If you want to create a new release, bump the version first"
    exit 1
fi

# Verify homebrew-tap is bundle-aware. The release.yml auto-bump rewrites
# the formula's URL + sha256, but does NOT touch the install block. With
# 0.0.18+ the tarball contains skhd.app/ instead of a bare binary, so a
# pre-bundle install block (`bin.install "skhd-arm64-macos" => "skhd"`)
# would silently produce broken installs after the auto-bump runs. Block
# the release until the formula has the bundle-aware install logic.
echo "Checking homebrew-tap formula is bundle-aware..."
HEAD_FORMULA=$(curl -fsSL https://raw.githubusercontent.com/jackielii/homebrew-tap/main/Formula/skhd-zig.rb 2>/dev/null || true)
if [ -z "$HEAD_FORMULA" ]; then
    echo -e "${YELLOW}Warning: could not fetch homebrew-tap formula${NC}"
    if ! confirm_yn "Continue anyway?"; then
        exit 1
    fi
elif ! echo "$HEAD_FORMULA" | grep -q 'File.directory?("skhd.app")'; then
    echo -e "${RED}Error: homebrew-tap/main formula is NOT bundle-aware.${NC}"
    echo "Releasing v$CURRENT_VERSION now will break 'brew install jackielii/tap/skhd-zig'"
    echo "for everyone, because the auto-bump rewrites a stale install block."
    echo ""
    echo "Merge the bundle-aware formula PR first, then re-run this script."
    exit 1
fi

echo -e "${GREEN}✓ Pre-flight checks passed${NC}"
echo ""

# Step 2: Pull latest changes
echo -e "${BLUE}[Step 2/$TOTAL_STEPS] Pulling latest changes from origin...${NC}"
git pull origin main
echo -e "${GREEN}✓ Up to date with origin${NC}"

# Step 3: Check/update CHANGELOG.md
echo ""
echo -e "${BLUE}[Step 3/$TOTAL_STEPS] Checking CHANGELOG.md...${NC}"
if ! grep -q "## \[$CURRENT_VERSION\]" CHANGELOG.md; then
    echo -e "${YELLOW}Warning: No changelog entry found for version $CURRENT_VERSION${NC}"
    echo "Using Claude to generate changelog entry..."

    # Get git diff since last tag
    LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    if [ -n "$LAST_TAG" ]; then
        GIT_LOG=$(git log --oneline $LAST_TAG..HEAD)
    else
        GIT_LOG=$(git log --oneline -20)
    fi

    # Use Claude to analyze changes and update CHANGELOG.md
    # --dangerously-skip-permissions allows file edits without prompts
    claude --dangerously-skip-permissions -p "Please analyze these git commits and update CHANGELOG.md with an entry for version $CURRENT_VERSION. Follow the existing format in the file. Here are the commits since the last release:

$GIT_LOG

Please add the new entry after ## [Unreleased] and before the previous version entry. Use the current date." CHANGELOG.md

    echo ""
    echo "CHANGELOG.md has been updated. Please review the changes."
    confirm_or_skip "Press Enter to continue with the updated changelog, or Ctrl+C to cancel"

    # Commit the changelog update
    git add CHANGELOG.md
    git commit -m "Update CHANGELOG.md for version $CURRENT_VERSION"
else
    echo -e "${GREEN}✓ CHANGELOG.md already has entry for $CURRENT_VERSION${NC}"
fi

# Step 4: Run tests
echo ""
echo -e "${BLUE}[Step 4/$TOTAL_STEPS] Running tests...${NC}"
if ! zig build test; then
    echo -e "${RED}Error: Tests failed${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Tests passed${NC}"

# Step 5: Build release artifacts (bare binary + .app bundle)
# The release pipeline ships skhd.app inside skhd-<arch>-macos.tar.gz, so
# verify the bundle layout builds cleanly here before tagging.
echo ""
echo -e "${BLUE}[Step 5/$TOTAL_STEPS] Building release artifacts...${NC}"
zig build -Doptimize=ReleaseFast
zig build app -Doptimize=ReleaseFast
test -f zig-out/skhd.app/Contents/MacOS/skhd || {
    echo -e "${RED}Error: skhd.app missing inner binary${NC}"
    exit 1
}
test -f zig-out/skhd.app/Contents/Info.plist || {
    echo -e "${RED}Error: skhd.app missing Info.plist${NC}"
    exit 1
}
echo -e "${GREEN}✓ Release artifacts built (bare binary + skhd.app bundle)${NC}"

# Step 6: Generate release notes using Claude
echo ""
echo -e "${BLUE}[Step 6/$TOTAL_STEPS] Generating release notes...${NC}"
CHANGELOG_ENTRY=$(awk "/## \[$CURRENT_VERSION\]/{flag=1; next} /## \[/{flag=0} flag" CHANGELOG.md)

RELEASE_NOTES=$(claude -p "Generate concise GitHub release notes for skhd.zig version $CURRENT_VERSION based on this changelog entry. Format it nicely with markdown, highlighting the most important changes first. Keep it user-friendly and avoid technical jargon where possible:\n\n$CHANGELOG_ENTRY" </dev/null)

echo ""
echo -e "${YELLOW}Release Notes:${NC}"
echo "----------------------------------------"
echo "$RELEASE_NOTES"
echo "----------------------------------------"
echo ""
if ! confirm_yn "Do you want to proceed with creating tag $TAG with these release notes?"; then
    echo -e "${RED}Release cancelled${NC}"
    exit 1
fi

# Step 7: Create tag and push
echo ""
echo -e "${BLUE}[Step 7/$TOTAL_STEPS] Creating and pushing tag...${NC}"
# --cleanup=verbatim: preserve markdown headings (lines starting with `#`).
# Default cleanup mode strips them as comments, which silently drops a
# leading "# Title" line from the release notes.
git tag -a "$TAG" --cleanup=verbatim -m "$RELEASE_NOTES"
echo -e "${GREEN}✓ Tag $TAG created${NC}"

echo "Pushing tag to origin..."
git push origin "$TAG"
echo -e "${GREEN}✓ Tag pushed to origin${NC}"

echo ""
echo "GitHub Actions will now automatically:"
echo "  - Build skhd.app bundles for both architectures (arm64 + x86_64)"
echo "  - Code-sign with skhd-cert (if MACOS_CERTIFICATE secret is set)"
echo "  - Create a GitHub release with skhd-<arch>-macos.tar.gz containing skhd.app"
echo "  - Update the Homebrew formula (URL + sha256)"

# Step 8: Bump version if requested
if [ "$BUMP_VERSION" = true ]; then
    echo ""
    echo -e "${BLUE}[Step 8/$TOTAL_STEPS] Bumping version for next development cycle...${NC}"
    
    # Parse current version
    IFS='.' read -r -a version_parts <<< "$CURRENT_VERSION"
    MAJOR="${version_parts[0]}"
    MINOR="${version_parts[1]}"
    PATCH="${version_parts[2]}"
    
    # Bump version based on type
    case $BUMP_TYPE in
        major)
            MAJOR=$((MAJOR + 1))
            MINOR=0
            PATCH=0
            ;;
        minor)
            MINOR=$((MINOR + 1))
            PATCH=0
            ;;
        patch)
            PATCH=$((PATCH + 1))
            ;;
        *)
            echo -e "${RED}Invalid bump type: $BUMP_TYPE${NC}"
            echo "Valid types: major, minor, patch"
            exit 1
            ;;
    esac
    
    NEW_VERSION="$MAJOR.$MINOR.$PATCH"
    
    # Update VERSION file
    echo "$NEW_VERSION" > VERSION
    
    # Commit and push
    git add VERSION
    git commit -m "Bump version to $NEW_VERSION for next development cycle"
    git push origin main

    echo -e "${GREEN}✓ Version bumped from $CURRENT_VERSION to $NEW_VERSION${NC}"
    echo "Development builds will now show as '$NEW_VERSION-dev-<commit>'"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                    Release Complete! 🎉${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"