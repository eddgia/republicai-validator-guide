# Cron Setup

## Auto-restart node (every 2 minutes)
```
*/2 * * * * /home/akonkat/auto-restart-node.sh >> /home/akonkat/auto-restart-node.log 2>&1
```

## Cron compute job (once per day at 8:00 UTC / 15:00 VN)
```
0 8 * * * /home/akonkat/cron-compute.sh >> /home/akonkat/cron-compute.log 2>&1
```

## Install crontab
```bash
crontab cron-setup.txt
```
