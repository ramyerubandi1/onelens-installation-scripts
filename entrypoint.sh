#!/bin/sh

# Define the URL of the new script
rm -rf  /install.sh
SCRIPT_URL="https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/refs/heads/master/install.sh"
echo "$SCRIPT_URL"
# Download the new script
curl -H 'Cache-Control: no-cache' -fsSL "$SCRIPT_URL" -o /install.sh

# Make the script executable
chmod +x /install.sh
# Run the new script
exec /install.sh 

