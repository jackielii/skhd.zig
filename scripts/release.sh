#!/bin/bash

# Script to create a release and optionally bump version for next cycle
# Usage: ./scripts/release.sh [--bump major|minor|patch]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
BUMP_VERSION=false
BUMP_TYPE="patch"
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
        *)
            echo "Usage: $0 [--bump major|minor|patch]"
            exit 1
            ;;
    esac
done

CURRENT_VERSION=$(cat VERSION)
TAG="v$CURRENT_VERSION"

echo "Preparing to release version $CURRENT_VERSION"
echo ""

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

# Pull latest changes
echo "Pulling latest changes from origin..."
git pull origin main

# Run tests
echo ""
echo "Running tests..."
if ! zig build test; then
    echo -e "${RED}Error: Tests failed${NC}"
    exit 1
fi
echo -e "${GREEN}Tests passed!${NC}"

# Build release binaries
echo ""
echo "Building release binaries..."
zig build -Doptimize=ReleaseFast

# Create tag
echo ""
echo -e "${YELLOW}Creating tag $TAG...${NC}"
git tag -a "$TAG" -m "Release $TAG"

echo ""
echo -e "${GREEN}Release $TAG created successfully!${NC}"

# Push tag
echo ""
echo "Pushing tag to origin..."
git push origin "$TAG"

echo ""
echo "GitHub Actions will now automatically:"
echo "- Build binaries for both architectures"
echo "- Create a GitHub release"
echo "- Update the Homebrew formula"

# Bump version if requested
if [ "$BUMP_VERSION" = true ]; then
    echo ""
    echo -e "${YELLOW}Bumping version for next development cycle...${NC}"
    
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
    
    echo ""
    echo -e "${GREEN}Version bumped from $CURRENT_VERSION to $NEW_VERSION${NC}"
    echo "Development builds will now show as '$NEW_VERSION-dev-<commit>'"
fi