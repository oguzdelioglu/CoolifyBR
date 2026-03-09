# CoolifyBR - Coolify Yedekleme & Geri Yükleme Aracı

Coolify instance'larınızı **komple**, **proje bazlı** veya **seçici** olarak yedekleyin ve başka bir sunucuya aktarın.

> 🇬🇧 [English documentation / İngilizce dokümantasyon için buraya tıklayın](README.md)

---

## Özellikler

- **3 Yedekleme Modu**: Full (komple), Project (proje bazlı), Selective (seçici)
- **PostgreSQL Database**: Coolify veritabanının tam veya proje bazlı yedeği
- **Docker Volumes**: Uygulama verilerinin otomatik tespiti ve yedeklenmesi
- **SSH Keys**: Coolify SSH anahtarlarının güvenli transferi
- **APP_KEY Yönetimi**: Otomatik APP_PREVIOUS_KEYS güncellemesi
- **Proxy Config**: Traefik/Caddy yapılandırma yedeği
- **Uzak Transfer**: SCP/rsync ile hedef sunucuya otomatik aktarım
- **Coolify API Entegrasyonu**: Proje/kaynak keşfi için API desteği
- **İnteraktif & CLI**: Hem menü tabanlı hem komut satırı kullanımı

## Gereksinimler

- Linux sunucu (Coolify'ın kurulu olduğu)
- Root erişimi
- Docker
- `jq`, `curl`, `tar`, `gzip`
- Uzak transfer için: `ssh`, `scp` veya `rsync`

## Kurulum

```bash
# Repoyu klonlayın
git clone https://github.com/oguzdelioglu/CoolifyBR.git
cd CoolifyBR

# Scriptleri çalıştırılabilir yapın
chmod +x coolify-backup.sh coolify-restore.sh

# (Opsiyonel) API token ayarlayın
cp config.env config.local.env
nano config.local.env  # COOLIFY_API_TOKEN değerini girin
```

## Hızlı Başlangıç

### Komple Yedekleme

```bash
sudo ./coolify-backup.sh --mode full
```

### Proje Bazlı Yedekleme

```bash
# İnteraktif proje seçimi
sudo ./coolify-backup.sh --mode project

# Belirli proje UUID ile
sudo ./coolify-backup.sh --mode project --project-uuid abc-123-def
```

### Seçici Yedekleme

```bash
sudo ./coolify-backup.sh --mode selective
```

### Yedekten Geri Yükleme

```bash
# Yedeği hedef sunucuya kopyalayın
scp backups/coolify-backup-full-20260308-143000.tar.gz root@yeni-sunucu:/tmp/

# Hedef sunucuda geri yükleyin
sudo ./coolify-restore.sh --file /tmp/coolify-backup-full-20260308-143000.tar.gz
```

### Direkt Transfer + Restore

```bash
# Yedekle ve uzak sunucuya aktar
sudo ./coolify-backup.sh --mode full --transfer 192.168.1.100

# Özel SSH ayarlarıyla
sudo ./coolify-backup.sh --mode full \
  --transfer 192.168.1.100 \
  --transfer-user root \
  --transfer-key ~/.ssh/id_rsa \
  --transfer-port 22
```

---

## Kullanım Detayları

### coolify-backup.sh

```
Modlar:
  --mode full          Komple Coolify instance (DB + volumes + SSH + proxy)
  --mode project       Belirli proje(ler)i yedekle
  --mode selective     İnteraktif kaynak seçimi

Seçenekler:
  --output DIR         Çıktı dizini (varsayılan: ./backups)
  --project-uuid UUID  Proje UUID (project modunda interaktif seçim yerine)
  --transfer HOST      Yedek sonrası uzak sunucuya aktar
  --transfer-user USER Uzak SSH kullanıcısı (varsayılan: root)
  --transfer-key PATH  Uzak transfer için SSH anahtarı
  --transfer-port PORT Uzak SSH portu (varsayılan: 22)
  --skip-volumes       Docker volume yedeklerini atla
  --skip-db            Veritabanı yedeğini atla
  --non-interactive    Sorgusuz çalıştır
```

### coolify-restore.sh

```
Seçenekler:
  --file PATH          Yedek arşivi yolu (.tar.gz)
  --mode MODE          Geri yükleme modu: full, selective (varsayılan: manifestten oku)
  --skip-volumes       Docker volume geri yüklemesini atla
  --skip-db            Veritabanı geri yüklemesini atla
  --skip-ssh           SSH anahtar geri yüklemesini atla
  --skip-env           .env geri yüklemesini atla
  --skip-proxy         Proxy yapılandırma geri yüklemesini atla
  --skip-restart       Coolify yeniden başlatmayı atla
  --non-interactive    Sorgusuz geri yükle (her şeyi geri yükle)
```

---

## Yedek Arşiv Yapısı

```
coolify-backup-full-20260308-143000.tar.gz
├── manifest.json           # Metadata (mod, tarih, sürüm, bileşenler)
├── database/
│   └── coolify-db.dump     # PostgreSQL dump (custom format)
├── volumes/
│   ├── vol1-backup.tar.gz  # Docker volume yedekleri
│   └── vol2-backup.tar.gz
├── ssh/
│   └── keys/               # SSH key dosyaları
├── env/
│   └── .env                # /data/coolify/source/.env kopyası (APP_KEY dahil)
└── proxy/
    └── proxy-config.tar.gz # Traefik/Caddy config
```

## Restore Adımları (Manuel)

Eğer scripti kullanamıyorsanız, yedekten manuel geri yükleme:

1. **Hedef sunucuya Coolify kurun** (aynı sürüm)
2. **Coolify container'larını durdurun**: `docker stop coolify coolify-redis coolify-realtime`
3. **DB'yi geri yükleyin**: `cat coolify-db.dump | docker exec -i coolify-db pg_restore --verbose --clean --no-acl --no-owner -U coolify -d coolify`
4. **SSH anahtarlarını kopyalayın**: `/data/coolify/ssh/keys/` altına
5. **APP_KEY'i ayarlayın**: `/data/coolify/source/.env` dosyasında `APP_PREVIOUS_KEYS=eski_key`
6. **Coolify'ı yeniden başlatın**: `curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash`

---

## Sorun Giderme

| Problem | Çözüm |
|---------|-------|
| 500 hatası login'de | `/data/coolify/source/.env` dosyasında `APP_PREVIOUS_KEYS` doğru ayarlandığından emin olun |
| İzin hatası | `sudo chown -R root:root /data/coolify` |
| Sunuculara SSH bağlanamıyor | SSH anahtarlarının doğru restore edildiğini kontrol edin |
| Docker volumes geri yüklenmiyor | Hedef sunucuda Docker'ın çalıştığından emin olun |
| API token hatası | `config.env` dosyasında token'ı kontrol edin |

---

## Lisans

MIT License
