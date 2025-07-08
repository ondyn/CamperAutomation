import os
import json
import shutil
import sys

try:
    # Path to the file to modify
    # file_path = "/data/data/com.termux/files/home/.suroot/.homeassistant/.storage/core.config_entries"
    file_path = sys.argv[2]

    # Get the IP address of the wlan0 interface
    ip_address = sys.argv[1]
    # subprocess.call('tsu ifconfig wlan0 | grep "inet " | awk -F"[: ]+" "{ print $3 }"').decode("utf-8")

    parts = ip_address.split(".")
    parts[-1] = "7"
    ip_address = ".".join(parts)

    # Backup the original file
    backup_path = "core.config_entries.bak"
    if os.path.exists(file_path):
        shutil.copy(file_path, backup_path)

    # Open the file for reading and writing
    with open(file_path, "r+") as file:
        # Load the file contents as a JSON object
        contents = json.load(file)

        # Replace the old text with the new text
        for entry in contents['data']['entries']:
            if entry['entry_id'] == '39bb02abde1417f5f7a5efb2f474bb1c':
                entry['data']['host'] = ip_address
        file.seek(0)
        file.truncate()
        json.dump(contents, file, indent=2)

    print("File updated successfully!")
except Exception as e:
    print("Error updating IP!")
    print(e)
    