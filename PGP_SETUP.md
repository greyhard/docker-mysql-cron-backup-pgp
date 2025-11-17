# PGP Encryption Setup Guide

This guide explains how to set up PGP encryption for your MySQL backups.

## Generating PGP Keys

### 1. Generate a new PGP key pair

```bash
# Generate key pair interactively
gpg --full-generate-key

# Or generate non-interactively
gpg --batch --gen-key <<EOF
Key-Type: RSA
Key-Length: 4096
Name-Real: MySQL Backup
Name-Email: backup@example.com
Expire-Date: 0
%no-protection
%commit
EOF
```

### 2. Export the public key

```bash
# List keys to find the key ID
gpg --list-keys

# Export public key (for encryption)
gpg --armor --export backup@example.com > ./secrets/pgp_public_key

# Or export by key ID
gpg --armor --export YOUR_KEY_ID > ./secrets/pgp_public_key
```

### 3. Export the private key

```bash
# Export private key (for decryption during restore)
gpg --armor --export-secret-keys backup@example.com > ./secrets/pgp_private_key

# Or export by key ID
gpg --armor --export-secret-keys YOUR_KEY_ID > ./secrets/pgp_private_key
```

## Directory Structure

Create a secrets directory:

```bash
mkdir -p secrets
chmod 700 secrets
```

Your secrets directory should look like:

```
secrets/
├── mysql_root_password
├── pgp_public_key
└── pgp_private_key
```

## Security Best Practices

1. **Never commit secrets to git**
   ```bash
   echo "secrets/" >> .gitignore
   ```

2. **Set proper permissions**
   ```bash
   chmod 600 secrets/*
   ```

3. **Use Docker Secrets in production**
   - For Docker Swarm, use `docker secret create`
   - For Kubernetes, use Sealed Secrets or external secret managers

4. **Rotate keys periodically**
   - Generate new keys every 1-2 years
   - Keep old private keys to decrypt old backups

## Testing Encryption

### Test encryption manually:

```bash
# Encrypt a test file
echo "test data" | gpg --batch --yes --trust-model always \
  --encrypt --recipient-file ./secrets/pgp_public_key > test.gpg

# Decrypt it
gpg --batch --yes --decrypt test.gpg
```

### Test with backup:

```bash
# Create a test backup with encryption
docker-compose exec backup /backup.sh

# Check that .gpg files were created
docker-compose exec backup ls -lh /backup/

# Test restore
docker-compose exec backup /restore.sh /backup/latest/mydb.sql.gz.gpg
```

## Troubleshooting

### "No public key" error

Make sure the PGP_KEY or PGP_KEY_FILE is properly set and the key is valid:

```bash
# Verify key is valid
gpg --import ./secrets/pgp_public_key
gpg --list-keys
```

### "Decryption failed" error

Ensure the private key is available and matches the public key used for encryption:

```bash
# Import and test private key
gpg --import ./secrets/pgp_private_key
gpg --list-secret-keys
```

### Permission denied

Check file permissions:

```bash
ls -la secrets/
# Should show: -rw------- (600)
```

## Example: Complete Setup

```bash
#!/bin/bash

# 1. Create secrets directory
mkdir -p secrets

# 2. Generate PGP key pair
gpg --batch --gen-key <<EOF
Key-Type: RSA
Key-Length: 4096
Name-Real: MySQL Backup
Name-Email: backup@example.com
Expire-Date: 0
%no-protection
%commit
EOF

# 3. Export keys
gpg --armor --export backup@example.com > secrets/pgp_public_key
gpg --armor --export-secret-keys backup@example.com > secrets/pgp_private_key

# 4. Create MySQL password file
echo "your_mysql_password" > secrets/mysql_root_password

# 5. Set permissions
chmod 700 secrets
chmod 600 secrets/*

# 6. Start services
docker-compose up -d

echo "Setup complete! Backups will be encrypted with PGP."
```

## Using with Docker Swarm

```bash
# Create secrets
docker secret create mysql_root_password secrets/mysql_root_password
docker secret create pgp_public_key secrets/pgp_public_key
docker secret create pgp_private_key secrets/pgp_private_key

# Deploy stack
docker stack deploy -c docker-compose.yml backup
```
