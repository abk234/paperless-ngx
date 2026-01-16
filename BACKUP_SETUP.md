# Automated Backup Setup for Paperless-ngx

This directory contains example files for setting up automated backups of your Paperless-ngx documents.

## Files

- `backup-paperless.sh.example` - Backup script that exports all documents to a ZIP file
- `com.paperless.backup.plist.example` - macOS LaunchAgent configuration for scheduled backups

## Setup Instructions

### 1. Copy the example files

```bash
cp backup-paperless.sh.example backup-paperless.sh
cp com.paperless.backup.plist.example com.paperless.backup.plist
```

### 2. Edit the plist file

Open `com.paperless.backup.plist` and replace the placeholder paths:
- Replace `/path/to/your/paperless-ngx/backup-paperless.sh` with the actual path to your `backup-paperless.sh` script
- Replace `/path/to/your/paperless-ngx/backup.log` with the actual path where you want the log file

### 3. Make the script executable

```bash
chmod +x backup-paperless.sh
```

### 4. Install the LaunchAgent (macOS)

```bash
cp com.paperless.backup.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.paperless.backup.plist
```

### 5. Verify the backup

The script will run every Sunday at 2:00 AM (as configured in the plist). You can test it manually:

```bash
./backup-paperless.sh
```

The exported ZIP file will be created in the `export/` directory.

## Notes

- The backup script uses dynamic path detection, so it will work regardless of where you place the repository
- The plist file requires absolute paths for macOS LaunchAgent to work properly
- Backup logs are written to `backup.log` in the repository root
- The actual backup files (`backup-paperless.sh`, `com.paperless.backup.plist`, `backup.log`) are in `.gitignore` to prevent committing personal paths
