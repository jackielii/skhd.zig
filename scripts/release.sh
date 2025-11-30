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
        *)
            echo "Usage: $0 [--bump major|minor|patch] [--no-bump]"
            echo "  Default: bump patch version after release"
            echo "  Use --no-bump to skip version bump"
            exit 1
            ;;
    esac
done

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
echo -e "${YELLOW}Press Enter to start, or Ctrl+C to cancel${NC}"
read -r
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
    echo -e "${YELLOW}Press Enter to continue with the updated changelog, or Ctrl+C to cancel${NC}"
    read -r

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

# Step 5: Build release binaries
echo ""
echo -e "${BLUE}[Step 5/$TOTAL_STEPS] Building release binaries...${NC}"
zig build -Doptimize=ReleaseFast
echo -e "${GREEN}✓ Release binaries built${NC}"

# Step 6: Generate release notes using Claude
echo ""
echo -e "${BLUE}[Step 6/$TOTAL_STEPS] Generating release notes...${NC}"
CHANGELOG_ENTRY=$(awk "/## \[$CURRENT_VERSION\]/{flag=1; next} /## \[/{flag=0} flag" CHANGELOG.md)

RELEASE_NOTES=$(claude -p "Generate concise GitHub release notes for skhd.zig version $CURRENT_VERSION based on this changelog entry. Format it nicely with markdown, highlighting the most important changes first. Keep it user-friendly and avoid technical jargon where possible:\n\n$CHANGELOG_ENTRY")

echo ""
echo -e "${YELLOW}Release Notes:${NC}"
echo "----------------------------------------"
echo "$RELEASE_NOTES"
echo "----------------------------------------"
echo ""
echo -e "${YELLOW}Do you want to proceed with creating tag $TAG with these release notes? (y/n)${NC}"
read -r CONFIRM

if [ "$CONFIRM" != "y" ]; then
    echo -e "${RED}Release cancelled${NC}"
    exit 1
fi

# Step 7: Create tag and push
echo ""
echo -e "${BLUE}[Step 7/$TOTAL_STEPS] Creating and pushing tag...${NC}"
git tag -a "$TAG" -m "$RELEASE_NOTES"
echo -e "${GREEN}✓ Tag $TAG created${NC}"

echo "Pushing tag to origin..."
git push origin "$TAG"
echo -e "${GREEN}✓ Tag pushed to origin${NC}"

echo ""
echo "GitHub Actions will now automatically:"
echo "  - Build binaries for both architectures"
echo "  - Create a GitHub release"
echo "  - Update the Homebrew formula"

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