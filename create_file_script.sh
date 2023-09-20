#!/bin/bash
file_to_create="dataBank.csv"
force_new_file="$FORCE_NEW_DATA_FILE"

# Check if the file already exists
if  [ ! "$force_new_file" = "true" ] && [ -e "$file_to_create" ]; then
    echo "Not making new data file"
else
    # If the file doesn't exist, create it
    cp dataHeaderNoData.csv "$file_to_create"
    echo "New data file created: $file_to_create"
fi