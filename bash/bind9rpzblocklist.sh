#!/bin/bash

# Blocklist Merger Script
# Merges two DNS blocklists into a single RPZ file

# Configuration
OUTPUT_FILE="rpz"
BACKUP_DIR="backup"
BACKUP_FILE="$BACKUP_DIR/rpz~"
TEMP_DIR="/tmp/blocklist_merge"
CONTAINER_NAME="bind9"
HAGEZI_URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/rpz/multi.txt"
OISD_URL="https://big.oisd.nl/rpz"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Blocklist Merger ===${NC}"
echo "Merging blocklists into: $OUTPUT_FILE"
echo "Container: $CONTAINER_NAME"
echo

# Check if named-checkzone is available
if ! command -v named-checkzone &> /dev/null; then
    echo -e "${RED}✗ named-checkzone is not available. Please install bind9-utils.${NC}"
    exit 1
fi

# Check if podman is available
if ! command -v podman &> /dev/null; then
    echo -e "${RED}✗ podman is not available.${NC}"
    exit 1
fi

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Create temporary directory
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# Function to download and validate a blocklist
download_blocklist() {
    local url="$1"
    local filename="$2"
    local filepath="$TEMP_DIR/$filename"
    
    echo -e "${YELLOW}Downloading: $url${NC}"
    
    if curl -s -f -o "$filepath" "$url"; then
        local line_count=$(wc -l < "$filepath")
        echo -e "${GREEN}✓ Downloaded $filename ($line_count lines)${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to download $filename${NC}"
        return 1
    fi
}

# Download both blocklists
echo "Step 1: Downloading blocklists..."
download_blocklist "$HAGEZI_URL" "hagezi.txt" || exit 1
download_blocklist "$OISD_URL" "oisd.txt" || exit 1
echo

# Process and merge files
echo "Step 2: Processing and merging blocklists..."

# Process Hagezi file
echo "Processing Hagezi blocklist..."
grep -v "^;" "$TEMP_DIR/hagezi.txt" | \
grep -v "^$" | \
grep -v "^@" | \
grep -v "SOA" | \
grep -v "NS" | \
grep -v "^\$" | \
grep -v "TTL" | \
sed 's/\s*IN\s*CNAME\s*\.//' | \
awk '{if($1 != "" && $1 !~ /^[[:space:]]*$/ && $1 !~ /^\$/ && $1 !~ /TTL/) print $1}' | \
sort -u > "$TEMP_DIR/hagezi_domains.txt"

# Process OISD file
echo "Processing OISD blocklist..."
grep -v "^;" "$TEMP_DIR/oisd.txt" | \
grep -v "^$" | \
grep -v "^@" | \
grep -v "SOA" | \
grep -v "NS" | \
grep -v "^\$" | \
grep -v "TTL" | \
sed 's/\s*IN\s*CNAME\s*\.//' | \
awk '{if($1 != "" && $1 !~ /^[[:space:]]*$/ && $1 !~ /^\$/ && $1 !~ /TTL/) print $1}' | \
sort -u > "$TEMP_DIR/oisd_domains.txt"

# Combine and deduplicate
echo "Combining domains..."
cat "$TEMP_DIR/hagezi_domains.txt" "$TEMP_DIR/oisd_domains.txt" | sort -u > "$TEMP_DIR/all_domains.txt"

# Check if we have any domains
if [ ! -s "$TEMP_DIR/all_domains.txt" ]; then
    echo -e "${RED}✗ No domains found after processing${NC}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Get counts
hagezi_count=$(wc -l < "$TEMP_DIR/hagezi_domains.txt")
oisd_count=$(wc -l < "$TEMP_DIR/oisd_domains.txt")
total_count=$(wc -l < "$TEMP_DIR/all_domains.txt")

echo "Hagezi domains: $hagezi_count"
echo "OISD domains: $oisd_count"
echo "Unique domains: $total_count"

# Create RPZ zone file
echo "Creating RPZ zone file..."
TEMP_RPZ="$TEMP_DIR/rpz_file"

# Write RPZ header
cat > "$TEMP_RPZ" << 'EOF'
$TTL 60
@       IN      SOA     localhost. admin.localhost. (
                        1       ; serial
                        3600    ; refresh
                        1800    ; retry
                        604800  ; expire
                        60      ; minimum
                        )
        IN      NS      localhost.

EOF

# Add domain entries
while read -r domain; do
    if [ -n "$domain" ] && [ "$domain" != "localhost" ]; then
        echo "${domain} IN      CNAME   ." >> "$TEMP_RPZ"
    fi
done < "$TEMP_DIR/all_domains.txt"

# Add final newline
echo "" >> "$TEMP_RPZ"

echo -e "${GREEN}✓ RPZ zone file created with $(wc -l < "$TEMP_RPZ") lines${NC}"
echo

# Validate with bind9
echo "Step 3: Validating RPZ file with bind9..."
if named-checkzone rpz "$TEMP_RPZ" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ RPZ file validation successful!${NC}"
else
    echo -e "${RED}✗ RPZ file validation failed!${NC}"
    echo "Error details:"
    named-checkzone rpz "$TEMP_RPZ"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Backup and deploy
echo
echo "Step 4: Backing up and deploying new RPZ file..."

if [ -f "$OUTPUT_FILE" ]; then
    cp "$OUTPUT_FILE" "$BACKUP_FILE"
    echo -e "${GREEN}✓ Existing RPZ file backed up to $BACKUP_FILE${NC}"
fi

cp "$TEMP_RPZ" "$OUTPUT_FILE"
echo -e "${GREEN}✓ New RPZ file deployed${NC}"

# Restart container
echo
echo "Step 5: Restarting bind9 container..."

echo "Stopping $CONTAINER_NAME container..."
if podman stop "$CONTAINER_NAME" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Container stopped${NC}"
else
    echo -e "${YELLOW}⚠ Container was not running or stop failed${NC}"
fi

echo "Starting $CONTAINER_NAME container..."
if podman start "$CONTAINER_NAME" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Container started${NC}"
else
    echo -e "${RED}✗ Failed to start container${NC}"
    echo "Restoring backup..."
    if [ -f "$BACKUP_FILE" ]; then
        cp "$BACKUP_FILE" "$OUTPUT_FILE"
        echo -e "${YELLOW}⚠ Backup restored${NC}"
    fi
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Verify container is running
sleep 2
if podman ps | grep -q "$CONTAINER_NAME"; then
    echo -e "${GREEN}✓ Container is running${NC}"
else
    echo -e "${RED}✗ Container may not have started properly${NC}"
fi

# Clean up
rm -rf "$TEMP_DIR"

echo
echo -e "${GREEN}=== RPZ blocklist deployment completed successfully! ===${NC}"
echo "Statistics:"
echo "  Hagezi domains: $hagezi_count"
echo "  OISD domains: $oisd_count"
echo "  Unique domains: $total_count"
echo "  Output file: $OUTPUT_FILE"
echo "  Backup: $BACKUP_FILE"
