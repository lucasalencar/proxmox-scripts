# Migração para `tank/data/mediaserver` - Isolamento do qBittorrent + Hardlinks

## 1. Passo a passo manual (rodar como `root` no Proxmox)

### 0. Prep e snapshot
```bash
# lista datasets pra conferir espaço/recordsize antes de criar o novo
zfs list -o name,mountpoint,used,recordsize,mounted | grep tank/data
# lista IDs dos LXCs/VMs pra usar nas variáveis QB/JF/CS
pct list; qm list
# cria snapshot recursivo pra rollback rápido se algo der errado
zfs snapshot -r tank/data@pre-mediaserver
```

### 1. Parar consumers
```bash
# descobre IDs automaticamente pelo nome
QB=$(pct list | grep -i qbittorrent | awk '{print $1}')
JF=$(pct list | grep -i jellyfin | awk '{print $1}')
CS=$(pct list | grep -i casaos | awk '{print $1}')
# para evitar escrita durante rsync/mv
pct stop $QB $JF $CS 2>/dev/null; echo "stopped"
# confere mounts atuais antes de apagar
pct config $QB | grep -E '^mp[0-9]+:'
```

### 2. Criar dataset `mediaserver`
```bash
# carrega helpers do repo (setup_dataset_acls, add_dataset_acl)
source /root/proxmox-scripts/common/functions.sh
# cria dataset único que vai conter media+downloads no mesmo FS (hardlink precisa disso)
zfs create tank/data/mediaserver
# desativa atime pra menos escrita em disco
zfs set atime=off tank/data/mediaserver
# 1M é ótimo pra mídia grande (herdado de media), tradeoff pra torrents pequenos
zfs set recordsize=1M tank/data/mediaserver
# habilita ACLs POSIX pra controle fino por UID
zfs set acltype=posixacl tank/data/mediaserver
zfs set xattr=sa tank/data/mediaserver
# cria estrutura: media e downloads como pastas, não datasets (ajustado pra sua organização)
mkdir -p /tank/data/mediaserver/{media,downloads}
# sua estrutura: Shows (shows de música), Movies, Series, Music (arquivos de música)
mkdir -p /tank/data/mediaserver/media/{Movies,Series,Music,Shows}
# downloads: categorias espelham media (shows pra Shows)
mkdir -p /tank/data/mediaserver/downloads/{series,movies,music,shows}
# aplica dono 1000 + container root 100000 com herança
setup_dataset_acls tank/data/mediaserver /tank/data/mediaserver 1000 100000
```

### 3. Migrar dados (rsync pra validar)
```bash
# copia preservando hardlinks, xattrs e ACLs, com progresso
rsync -aHAX --info=progress2 /tank/data/media/ /tank/data/mediaserver/media/
rsync -aHAX --info=progress2 /tank/data/downloads/ /tank/data/mediaserver/downloads/
# se você está renomeando Concerts -> Shows (caso atual), renomeia só no destino
# mantém origem intacta até validação do passo 9
[ -d /tank/data/mediaserver/media/Concerts ] && mv /tank/data/mediaserver/media/Concerts /tank/data/mediaserver/media/Shows
# compara tamanho total pra validar cópia (devem bater)
du -sh /tank/data/media /tank/data/mediaserver/media
du -sh /tank/data/media/Concerts /tank/data/mediaserver/media/Shows 2>/dev/null; echo "Concerts->Shows OK se tamanhos baterem"
du -sh /tank/data/downloads /tank/data/mediaserver/downloads
# confere árvore nova rapidamente (deve ter Shows, não Concerts)
ls -R /tank/data/mediaserver | head -n 50
```

### 4. ACL por serviço (UID mapeado 100000+)
```bash
# descobre UID interno do serviço e mapeia pro host (+100000) e libera no dataset
# usa helper centralizado (interrompe caller via return + || exit)
host_qb=$(get_host_uid "$QB" qbittorrent || get_host_uid "$QB" root) || exit 1
add_dataset_acl /tank/data/mediaserver "$host_qb"

# Jellyfin precisa ler mediaserver/media
host_jf=$(get_host_uid "$JF" jellyfin) || exit 1
add_dataset_acl /tank/data/mediaserver/media "$host_jf"

# CasaOS: como qBittorrent vai pro LXC standalone, não precisa mais de 101000 (docker)
# se quiser expor downloads no CasaOS (FileBrowser), descomente as 2 linhas abaixo
# CS_UID=$(pct exec "$CS" -- id -u root); add_dataset_acl /tank/data/mediaserver $((CS_UID+100000))
# add_dataset_acl /tank/data/mediaserver 101000 2>/dev/null || true
host_cs=$(get_host_uid "$CS" root) || exit 1
add_dataset_acl /tank/data/mediaserver "$host_cs"
```

### 5. Remontar LXC com 1 mount isolado
```bash
# qBittorrent: antes /tank/data -> /data (expunha tudo), agora só mediaserver -> /data
pct stop $QB
# remove mounts antigos (evita conflito mp0/mp1)
pct set $QB -delete mp0 2>/dev/null; pct set $QB -delete mp1 2>/dev/null; pct set $QB -delete mp2 2>/dev/null
# monta dataset isolado como /data (dentro vê /data/media e /data/downloads no mesmo FS)
pct set $QB -mp1 /tank/data/mediaserver,mp=/data
# inicia e espera responder a pct exec
pct start $QB; wait_container_ready $QB
# deve listar só media e downloads, não lucas/memorias
pct exec $QB -- ls -l /data

# Jellyfin: monta só media pra não indexar incompletos como biblioteca
pct stop $JF
pct set $JF -delete mp0 2>/dev/null; pct set $JF -delete mp1 2>/dev/null; pct set $JF -delete mp2 2>/dev/null
pct set $JF -mp1 /tank/data/mediaserver/media,mp=/DATA/Media
pct set $JF -mp2 /tank/data/memorias,mp=/DATA/Gallery
pct start $JF; wait_container_ready $JF
# IMPORTANTE Jellyfin: library Concerts -> Shows renomeada no passo 3
# Dashboard > Libraries > edite Concerts e troque pasta de /DATA/Media/Concerts pra /DATA/Media/Shows, depois Scan

# CasaOS: mantém atalho /DATA/Downloads pro FileBrowser, agora apontando pro mediaserver
pct stop $CS
pct set $CS -delete mp0 2>/dev/null; pct set $CS -delete mp1 2>/dev/null; pct set $CS -delete mp2 2>/dev/null; pct set $CS -delete mp3 2>/dev/null
pct set $CS -mp1 /tank/data/memorias,mp=/DATA/Gallery
pct set $CS -mp2 /tank/data/mediaserver/media,mp=/DATA/Media
pct set $CS -mp3 /tank/data/mediaserver/downloads,mp=/DATA/Downloads
pct start $CS; wait_container_ready $CS
```

### 6. Ajustar qBittorrent (TRaSH Basic-Setup)
`http://<qbittorrent-ip>:8090` > `Tools > Options`:
* `Downloads > Saving Management`: `Default Save Path = /data/downloads`, `Torrent Management Mode = Automatic`, `Categories enabled`
* Categories: `series -> /data/downloads/series`, `movies -> /data/downloads/movies`, `music -> /data/downloads/music`, `shows -> /data/downloads/shows`
* `*arr` futuros: Root Folder `/data/media/{Movies,Series,Music,Shows}` (não `/data/mediaserver/...`)

### 7. Validação
```bash
# cria arquivo fake em downloads
pct exec $QB -- touch /data/downloads/series/.hardlink-test
# tenta hardlink pra media (mesmo FS deve funcionar, cross-device falha)
pct exec $QB -- ln /data/downloads/series/.hardlink-test /data/media/Series/.hardlink-test && echo "hardlink OK" || echo "FAIL - ainda cross-device"
# inodes iguais provam hardlink, não cópia
pct exec $QB -- stat -c '%i %n' /data/downloads/series/.hardlink-test /data/media/Series/.hardlink-test
# limpa teste
pct exec $QB -- rm /data/downloads/series/.hardlink-test /data/media/Series/.hardlink-test
# não deve listar dados privados do host
pct exec $QB -- ls /data
# deve negar acesso a dataset privado (ACL o::-)
pct exec $QB -- ls /data | grep -q "lucas" && echo "FAIL: isolamento quebrou" || echo "ACL/isolamento OK: lucas não exposto"
# pega IP pra testar WebUI/Caddy
pct exec $QB -- hostname -I
```

### 8. Atualizar código (próximas instalações)
* `proxmox/storage-setup/001-create-datasets.sh:12-15,25-31,59-61` - criar `tank/data/mediaserver` em vez de `media`+`downloads` separados
* `qbittorrent/install.sh:18,22,36-37` - `mkdir -p /tank/data/mediaserver/media/{Movies,Series,Music,Shows}` + `mkdir -p /tank/data/mediaserver/downloads/{series,movies,music,shows}` + `apply_mounts $id /tank/data/mediaserver /data`
* `qbittorrent/README.md:64` - árvore `/tank/data/mediaserver -> /data`
* `jellyfin/install.sh:34` apontar pra `mediaserver/media`; `casa-os/install.sh:60` apontar pra `mediaserver/media` (remover `mediaserver/downloads` e ACL `101000` já que qBittorrent sai do Docker)
* `caddy/generate-caddyfile.sh` - sem mudança (detecta 8090)

### 9. Limpeza (só após 1 semana estável)
```bash
# compara uso antes de destruir pra garantir que nada ficou pra trás
zfs list -o name,used,referenced tank/data/mediaserver tank/data/media tank/data/downloads
# remove datasets antigos (agora pastas dentro de mediaserver)
zfs destroy tank/data/media
zfs destroy tank/data/downloads
# remove snapshot de segurança
zfs destroy -r tank/data@pre-mediaserver
```

### Rollback
```bash
# restaura tudo ao snapshot inicial
zfs rollback -r tank/data@pre-mediaserver
# volta mounts antigos
pct set $QB -delete mp1; pct set $QB -mp1 /tank/data,mp=/data
pct set $JF -delete mp1; pct set $JF -mp1 /tank/data/media,mp=/DATA/Media
```

## 4. Notas
* `mediaserver` vs `arr`/`stack`: `mediaserver` é genérico e não amarra a `*arr`; `arr` é mais buscável no Reddit/TRaSH.
* `tank` não é especial - é só nome do pool. Pode renomear pool, mas dá trabalho (`zpool export/import`).
* Se no futuro precisar quota/snapshot separado de `media` vs `downloads`, não poderá - são 1 dataset. Tradeoff aceito pra hardlink + isolamento.
