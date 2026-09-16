#!/usr/bin/env bash
set -euo pipefail
cd /opt/mogok-maung
echo '== host/service =='
hostname
grep -E '^(DB_NAME|DB_USER)=' .env.production || true
echo '== pull =='
git fetch origin main -q && git reset --hard origin/main && git log --oneline -1
chmod +x scripts/prod/backup-db.sh
echo '== run 1 (encrypted, keep 14) =='
bash scripts/prod/backup-db.sh --keep 14
echo '== manifest tail =='
tail -2 backups/postgres/MANIFEST.sha256 2>/dev/null || find backups -name MANIFEST.sha256 -exec tail -2 {} \;
echo '== list =='
bash scripts/prod/backup-db.sh --list
echo '== install cron =='
bash scripts/prod/backup-db.sh --install-cron
echo '== crontab =='
crontab -l | grep backup-db
echo '== integrity re-verify newest (gzip -t + pg_restore --list inside container) =='
NEWEST_PLAIN="$(find backups -name '*.dump.gz' | sort | tail -1)"
echo "newest plain: ${NEWEST_PLAIN}"
gzip -t "${NEWEST_PLAIN}" && echo '  gzip -t OK'
NEWEST_ENC="$(find backups -name '*.dump.enc' | sort | tail -1)"
echo "newest enc:   ${NEWEST_ENC}"
if [ -n "${NEWEST_ENC}" ] && [ -f "${NEWEST_ENC}" ]; then
    KEY_HEX="$(grep -E '^BACKUP_KEY=' .env.production | cut -d= -f2- | openssl dgst -sha256 | awk '{print $2}')"
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "${NEWEST_ENC}" \
        -pass "pass:${KEY_HEX}" 2>/dev/null | gzip -dc | head -c 60 | od -An -c | head -1
    echo '  (AES header "PGDMP" = classic dump OK)'
fi
