# CoolifyBR - Coolify Yedekleme & Geri Yükleme Aracı

Coolify instance'larınızı **komple**, **proje bazlı** veya **seçici** olarak yedekleyin ve başka bir sunucuya aktarın.

> 🇬🇧 [English documentation / İngilizce dokümantasyon için buraya tıklayın](README.md)

---

## Özellikler

- **Birleşik CLI**: Yedekleme, geri yükleme, uzak pull job'ları, doğrulama ve kurulum için tek `coolifybr` giriş noktası
- **Kurulum Scripti**: Scriptleri, CLI symlink'ini ve örnek config dosyalarını tek komutla hazırlar
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

## Hızlı Başlangıç

```bash
git clone https://github.com/oguzdelioglu/CoolifyBR.git
cd CoolifyBR
./scripts/install.sh --profile source-server
coolifybr help
```

NAS / yedek sunucu için:

```bash
./scripts/install.sh --profile backup-host
```

Kurulum dokümantasyonu: [docs/INSTALL.md](docs/INSTALL.md)

---

# Yedekleme Kurulumu (Kaynak Sunucu)

Bu adımları **Coolify'ın halihazırda çalıştığı** ve yedeğini almak istediğiniz sunucuda uygulayın.

## 1. CoolifyBR'yi Kurun

```bash
ssh root@KAYNAK_SUNUCU_IP
git clone https://github.com/oguzdelioglu/CoolifyBR.git
cd CoolifyBR
./scripts/install.sh --profile source-server
```

## 2. (Opsiyonel) API Token Ayarlayın

CoolifyBR, projelerinizi Coolify API üzerinden keşfedebilir. Bu opsiyoneldir — token ayarlanmazsa araç doğrudan veritabanı sorgusu kullanır.

```bash
cp config.env config.local.env
nano config.local.env
```

Aşağıdaki değeri girin (token'ı **Coolify Dashboard → Keys & Tokens → API Tokens** bölümünden alabilirsiniz):

```
COOLIFY_API_TOKEN=api-tokeniniz-buraya
```

> Coolify yapılandırma dosyası `/data/coolify/source/.env` konumundadır. CoolifyBR, APP_KEY ve diğer ayarları bu dosyadan otomatik olarak okur.

## 3. Yedekleme Çalıştırın

### Komple Instance Yedekleme

Tüm Coolify instance'ını yedekler: veritabanı, tüm Docker volume'ları, SSH anahtarları, ortam yapılandırması ve proxy ayarları.

```bash
sudo coolifybr backup --mode full
```

### Proje Bazlı Yedekleme

Bir veya daha fazla belirli projeyi yedekler. İnteraktif menü ile hangi projeleri dahil edeceğinizi seçersiniz.

```bash
sudo coolifybr backup --mode project
sudo coolifybr backup --mode project --project-uuid abc-123-def
```

### Seçici Yedekleme

Tam olarak neyin dahil edileceğini seçin: veritabanı, belirli container volume'ları, SSH anahtarları, ortam yapılandırması.

```bash
sudo coolifybr backup --mode selective
```

### Yedekleme Seçenekleri

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

## 4. Hedef Sunucuya Transfer

Yedek oluşturulduktan sonra `.tar.gz` arşivini hedef sunucuya aktarmanız gerekir.

### Seçenek A: Manuel SCP

```bash
scp backups/coolify-backup-full-20260308-143000.tar.gz root@YENI_SUNUCU:/tmp/
```

### Seçenek B: Otomatik Transfer (dahili)

CoolifyBR, yedeği oluşturduktan sonra doğrudan transfer edebilir:

```bash
sudo coolifybr backup --mode full --transfer 192.168.1.100
```

Özel SSH ayarlarıyla:

```bash
sudo coolifybr backup --mode full \
  --transfer 192.168.1.100 \
  --transfer-user root \
  --transfer-key ~/.ssh/id_rsa \
  --transfer-port 22
```

Araç, rsync varsa onu kullanır, yoksa SCP'ye geçer. Ayrıca uzak sunucuda restore'u otomatik çalıştırmayı da teklif eder.

---

# Geri Yükleme Kurulumu (Hedef Sunucu)

Bu adımları Coolify'ı geri yüklemek istediğiniz **yeni/hedef sunucuda** uygulayın.

## 1. Hedef Sunucuya Coolify Kurun

Geri yüklemeden **önce** Coolify kurulu olmalıdır. Aynı (veya uyumlu) sürümü kurun:

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

Coolify'ın tamamen başlamasını bekleyin. Çalıştığını doğrulayın:

```bash
docker ps --filter "name=coolify"
```

Şu container'ları görmelisiniz: `coolify`, `coolify-db`, `coolify-redis`, `coolify-realtime` ve `coolify-proxy`.

## 2. Hedef Sunucuya CoolifyBR Kurun

```bash
ssh root@HEDEF_SUNUCU_IP
git clone https://github.com/oguzdelioglu/CoolifyBR.git
cd CoolifyBR
./scripts/install.sh --profile source-server
```

## 3. Yedek Arşivini Kopyalayın

Yedeği henüz transfer etmediyseniz:

```bash
# Yerel makinenizden veya kaynak sunucudan
scp /yedek/yolu/coolify-backup-full-20260308-143000.tar.gz root@HEDEF_SUNUCU:/tmp/
```

## 4. Geri Yüklemeyi Çalıştırın

```bash
sudo coolifybr restore --file /tmp/coolify-backup-full-20260308-143000.tar.gz
```

Restore scripti sırasıyla şunları yapar:

1. Yedek arşivini çıkarır
2. Manifest dosyasını okur ve yedek bilgilerini gösterir
3. Coolify container'larını durdurur (`coolify-db` çalışır kalır)
4. PostgreSQL veritabanını dump'tan geri yükler
5. Tüm Docker volume'larını geri yükler
6. SSH anahtarlarını geri yükler ve authorized_keys dosyasını birleştirir
7. `/data/coolify/source/.env` dosyasında `APP_PREVIOUS_KEYS` günceller (eski APP_KEY çalışmaya devam eder)
8. Proxy (Traefik/Caddy) yapılandırmasını geri yükler
9. Tüm Coolify container'larını yeniden başlatır

### Geri Yükleme Seçenekleri

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

### Seçici Geri Yükleme

Sadece belirli kısımları geri yüklemek istiyorsanız:

```bash
sudo coolifybr restore --file /tmp/backup.tar.gz --skip-volumes --skip-ssh --skip-proxy
sudo coolifybr restore --file /tmp/backup.tar.gz --mode selective
sudo coolifybr restore --file /tmp/backup.tar.gz --non-interactive
```

## 5. Geri Yükleme Sonrası Doğrulama

Geri yükleme tamamlandıktan sonra:

1. **Coolify dashboard'u açın** ve giriş yapabildiğinizi doğrulayın
2. **Projeleri ve deployment'ları kontrol edin** — görünür ve doğru olduklarından emin olun
3. **SSH bağlantılarını test edin** — yönetilen sunuculara bağlantıyı deneyin (Ayarlar → SSH Keys)
4. **Uygulamaları yeniden deploy edin** — çalışmayan container'lar varsa
5. **DNS kayıtlarını güncelleyin** — sunucu IP'si değiştiyse

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

## Manuel Geri Yükleme (CoolifyBR Olmadan)

Restore scriptini kullanamıyorsanız, manuel olarak yapın:

1. **Hedef sunucuya Coolify kurun** (aynı sürüm)
2. **Coolify container'larını durdurun**: `docker stop coolify coolify-redis coolify-realtime`
3. **Veritabanını geri yükleyin**:
   ```bash
   cat coolify-db.dump | docker exec -i coolify-db pg_restore \
     --verbose --clean --no-acl --no-owner -U coolify -d coolify
   ```
4. **SSH anahtarlarını kopyalayın** ve izinleri ayarlayın:
   ```bash
   cp backup/keys/* /data/coolify/ssh/keys/
   chmod 600 /data/coolify/ssh/keys/*
   ```
5. **APP_KEY'i ayarlayın** — yedekteki eski APP_KEY'i `/data/coolify/source/.env` dosyasına ekleyin:
   ```bash
   echo "APP_PREVIOUS_KEYS=yedekteki_eski_key" >> /data/coolify/source/.env
   ```
6. **Coolify'ı yeniden başlatın**:
   ```bash
   cd /data/coolify/source && docker compose up -d
   ```

---

## Sorun Giderme

| Problem | Çözüm |
|---------|-------|
| 500 hatası login'de | `/data/coolify/source/.env` dosyasında `APP_PREVIOUS_KEYS` doğru ayarlandığından emin olun |
| İzin hatası | `sudo chown -R root:root /data/coolify` komutunu çalıştırın |
| Sunuculara SSH bağlanamıyor | `/data/coolify/ssh/keys/` altındaki SSH anahtarlarının doğru restore edildiğini kontrol edin |
| Docker volumes geri yüklenmiyor | Hedef sunucuda Docker'ın çalıştığından emin olun |
| API token hatası | `config.env` dosyasındaki token'ı kontrol edin |
| Veritabanı restore başarısız | `coolify-db` container'ının çalıştığından emin olun: `docker start coolify-db` |
| Coolify restore sonrası başlamıyor | `cd /data/coolify/source && docker compose up -d` komutunu çalıştırın |

---

## Lisans

MIT License
