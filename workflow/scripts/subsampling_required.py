# !/usr/bin/env python3
# Determine if subsampling is required based on existing folders and a
# reference timestamp. Each folder in the directory is named with an ISO 8601
# timestamp representing the start of a one-hour interval. If any folder's
# interval overlaps with or is newer than the reference timestamp, subsampling
# is not required. If no such folder exists, subsampling is required. The script
# outputs "True" if subsampling is required and "False" otherwise.
import sys
import os
from datetime import datetime, timedelta

def main():
    if len(sys.argv) != 3:
        print("Usage: python subsampling_required.py <directory> <timestamp>")
        sys.exit(1)

    directory = sys.argv[1]
    ref_timestamp_str = sys.argv[2]

    print("Checking directory:", directory, "for subsampling requirement against timestamp:", ref_timestamp_str, file=sys.stderr)

    try:
        ref_time = datetime.fromisoformat(ref_timestamp_str)
    except ValueError:
        print(f"Error: Invalid timestamp format for '{ref_timestamp_str}'. Expected ISO 8601.", file=sys.stderr)
        sys.exit(1)

    if not os.path.isdir(directory):
        # If directory doesn't exist, we definitely need to process/subsample
        print("True")
        return

    found_recent = False

    for item in sorted(os.listdir(directory)):
        item_path = os.path.join(directory, item)
        if os.path.isdir(item_path):
            try:
                # Attempt to parse folder name as timestamp
                folder_time = datetime.fromisoformat(item)
                # Each folder represents one hour
                folder_end_time = folder_time + timedelta(hours=1)
                if folder_end_time >= ref_time:
                    # Found a folder within an hour before ref_time or newer
                    # than ref_time.
                    found_recent = True
                    print("Found recent folder:", item, file=sys.stderr)
                    break
            except ValueError:
                # Folder name is not a valid timestamp, ignore it
                continue

    # If we found a recent folder, we don't need to subsample (False).
    # If we didn't find one, we do need to subsample (True).
    if found_recent:
        print("False")
    else:
        print("True")

if __name__ == "__main__":
    main()
