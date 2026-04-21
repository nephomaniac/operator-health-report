#!/usr/bin/env bash
#
# Validation Script for Sanitization
# Checks staged files for sensitive data before commit
#

set -e

echo "=================================="
echo "SANITIZATION VALIDATION"
echo "=================================="
echo ""

errors=0

# Check if there are any staged files
if ! git diff --cached --quiet 2>/dev/null; then
    echo "✓ Found staged changes to validate"
    echo ""
else
    echo "⚠ No staged changes found"
    echo "Run 'git add' first, then run this script"
    exit 1
fi

echo "Checking staged files for sensitive data..."
echo ""

# 1. Check for cluster IDs (32-character alphanumeric strings)
echo "1. Checking for cluster IDs..."
if git diff --cached | grep -qE "\b[0-9a-z]{32}\b"; then
    echo "  ❌ FAIL: Found potential cluster IDs in staged changes"
    echo "  Lines:"
    git diff --cached | grep -nE "\b[0-9a-z]{32}\b" | head -10
    errors=$((errors + 1))
else
    echo "  ✓ PASS: No cluster IDs found"
fi
echo ""

# 2. Check for user-specific paths
echo "2. Checking for user-specific paths..."
if git diff --cached | grep -qE "/Users/[^/]+|/home/[^/]+"; then
    echo "  ❌ FAIL: Found user-specific paths in staged changes"
    echo "  Lines:"
    git diff --cached | grep -nE "/Users/[^/]+|/home/[^/]+" | head -10
    errors=$((errors + 1))
else
    echo "  ✓ PASS: No user-specific paths found"
fi
echo ""

# 3. Check for internal hostnames/domains
echo "3. Checking for internal hostnames..."
if git diff --cached | grep -qE "app-interface|gitlab\.corp|\.redhat\.com|\.corp\.redhat"; then
    echo "  ⚠ WARNING: Found potential internal hostnames"
    echo "  (May be acceptable in comments/documentation)"
    echo "  Lines:"
    git diff --cached | grep -nE "app-interface|gitlab\.corp|\.redhat\.com|\.corp\.redhat" | head -10
    echo ""
    echo "  Review these manually to ensure they're in documentation only"
fi
echo ""

# 4. Check for hard-coded staging cluster names
echo "4. Checking for hard-coded cluster names..."
# Only check additions (lines starting with +), not deletions (lines starting with -)
# Exclude validate_sanitization.sh itself (which contains these patterns in grep commands)
if git diff --cached -- ':!validate_sanitization.sh' | grep "^+" | grep -qE "camo-hive-stage|camo-hives\d+"; then
    echo "  ❌ FAIL: Found hard-coded staging cluster names"
    echo "  Lines:"
    git diff --cached -- ':!validate_sanitization.sh' | grep "^+" | grep -nE "camo-hive-stage|camo-hives\d+" | head -10
    errors=$((errors + 1))
else
    echo "  ✓ PASS: No hard-coded cluster names found"
fi
echo ""

# 5. Check for specific OCM config paths
echo "5. Checking for hard-coded OCM config paths..."
if git diff --cached | grep -qE "export OCM_CONFIG=.*ocm\.(stg|prod)\.json"; then
    echo "  ❌ FAIL: Found hard-coded OCM config path"
    echo "  Lines:"
    git diff --cached | grep -nE "export OCM_CONFIG=.*ocm\.(stg|prod)\.json" | head -10
    errors=$((errors + 1))
else
    echo "  ✓ PASS: No hard-coded OCM config paths found"
fi
echo ""

# 6. Check for email addresses
echo "6. Checking for email addresses..."
if git diff --cached | grep -qE "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" | grep -v "@example.com" | grep -v "noreply@anthropic.com"; then
    echo "  ⚠ WARNING: Found email addresses"
    echo "  (Verify these are generic/acceptable)"
    echo "  Lines:"
    git diff --cached | grep -E "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" | grep -v "@example.com" | grep -v "noreply@anthropic.com" | head -10
    echo ""
fi
echo ""

# 7. List all files being staged
echo "7. Files staged for commit:"
git diff --cached --name-only | while read file; do
    echo "  - $file"
done
echo ""

# Summary
echo "=================================="
echo "VALIDATION SUMMARY"
echo "=================================="
if [ $errors -eq 0 ]; then
    echo "✓ All checks passed!"
    echo ""
    echo "You can now commit with:"
    echo "  git commit -m 'Initial commit: Operator Health Report'"
else
    echo "❌ Found $errors error(s)"
    echo ""
    echo "Please fix the issues above before committing"
    exit 1
fi
