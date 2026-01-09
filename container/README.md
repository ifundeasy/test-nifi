# How to use (now + later with nifi4)

### 1) Make scripts executable

```bash
chmod +x 01-init-ca.sh 02-add-nodes.sh 03-make-client-admin.sh
```

### 2) Create CA once

```bash
./01-init-ca.sh
```

### 3) Create node materials for initial cluster

```bash
PW='ChangeMe123456' ./02-add-nodes.sh nifi1 nifi2 nifi3
```

### 4) Create admin client cert

```bash
PW='ChangeMe123456' ./03-make-client-admin.sh
```

### 5) Later: add `nifi4` (no CA regen)

```bash
PW='ChangeMe123456' ./02-add-nodes.sh nifi4
```