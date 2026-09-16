#!/bin/bash
BACKUP_DIR="$HOME/backups"
mkdir -p "$BACKUP_DIR"
STAMP=$(date +%Y-%m-%d_%H%M)
tar -czf "$BACKUP_DIR/world_$STAMP.tar.gz" -C "$HOME/mc" world
find "$BACKUP_DIR" -name 'world_*.tar.gz' -mtime +14 -delete
rclone copy "$BACKUP_DIR" gdrive:mc-backups/ --transfers 1
rclone delete gdrive:mc-backups/ --min-age 30d
