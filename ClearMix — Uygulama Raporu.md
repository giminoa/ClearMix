# ClearMix — Uygulama Raporu

*macOS için açık kaynak ses mikseri + mikrofon gürültü temizleyici · Hazırlayan: Claude · 10 Kasım 2026*

## 1. Özet

**Ne yapıyoruz?** Menü çubuğunda yaşayan tek bir macOS uygulaması: (1) her uygulamanın sesini ayrı kontrol eden bir mikser, (2) mikrofonu gerçek zamanlı temizleyip Discord, Zoom, OBS gibi uygulamalara sanal mikrofon olarak sunan bir gürültü filtresi. Çalışma adı **ClearMix**; isim çakışmasını başlamadan kontrol et.

**Nereden başlıyoruz?** Önerim: MIT lisanslı **Fabar**’ı temel al, ayrı bir repoya taşı ve kendi markanla yayımla. Fabar beklentini karşılamazsa yedek plan GPLv3 lisanslı **FineTune**; bu durumda projen de GPLv3 olur. Karar, 1 günlük bir keşif çalışmasıyla verilir (Bölüm 3).

**Nasıl yapıyoruz?** Swift + SwiftUI, Core Audio process tap’leri (sürücüsüz, uygulama bazlı ses), RNNoise (gürültü modeli), BlackHole (sanal mikrofon çıkışı). Her şey yerelde çalışır, telemetri yok.

**Ne kadar sürer?** Akşam ve hafta sonu temposuyla 1.0 için yaklaşık 4–6 hafta; ilk çalışan prototip birkaç gün. Bu bir tahmin: en büyük belirsizlik ses hatalarının ayıklanması.

**Hiçbir şey eksiltilmedi.** İstediğin her özellik kapsamda; sadece sıralandı (Bölüm 5). Benim eklediğim öneriler ⭐ ile işaretli.

## 2. Ürün ve fark

Bu alan boş değil, bu yüzden farkı baştan net koymak gerekiyor.

| Proje | Lisans / fiyat | Ne yapıyor |
| --- | --- | --- |
| SoundSource | Freemium, kapalı kaynak | Uygulama bazlı ses, yönlendirme, efektler; ticari referans |
| Background Music | Açık kaynak | Uygulama bazlı ses, sistem sesi kaydı; 19 bin+ yıldız, sanal sürücü tabanlı |
| eqMac | Açık kaynak | Sistem geneli EQ; bir kaynağa göre uygulama bazlı kontrol ücretli sürümde |
| FineTune | GPLv3 | Uygulama bazlı ses, çoklu cihaz yönlendirme, 10 bant EQ, %400 boost; \~10 bin yıldız |
| Fabar | MIT | Sade uygulama bazlı ses, sürücü gerektirmez; Mayıs 2026’da açılmış |
| Aurio | Ücretli (\~40 $) | Mikrofon temizleme + sanal mikrofon |
| Crispy, VoidMic | Açık kaynak | RNNoise + BlackHole ile mikrofon temizleme (Crispy kayıt/transkripsiyon odaklı) |

**ClearMix’in farkı:** tek uygulamada mikser + mikrofon temizleme, ücretsiz ve açık kaynak, “Discord’a hazır” tek tıkla kurulum, Türkçe/İngilizce arayüz.

**Not:** Discord’un kendi gürültü bastırması var. ClearMix’in değeri sistem geneli olması: OBS, Zoom, oyun içi sohbet gibi diğer uygulamalar da temiz sesi alır ve mikserle aynı yerden yönetilir.

## 3. Fork kararı

| Seçenek | Lisans sonucu | Artı | Eksi |
| --- | --- | --- | --- |
| **A. Fabar (önerilen)** | MIT: istediğin lisansla yayımlarsın, telif notunu korumak yeter | Küçük ve odaklı kod, sürücüsüz, macOS 14.4+ | Genç proje; kalite ve bakım durumu doğrulanmalı, özellik az |
| **B. FineTune** | GPLv3: türev çalışma da GPLv3 olur | Olgun: çoklu cihaz yönlendirme, EQ, boost, 17 katkıcı | Proje “senin” hissettirmez, upstream ile birleştirme yükü, bakımcı iddiası zayıflar; minimum macOS sürümü kaynaklarda farklı (14.2 / 15+) |
| C. Background Music | GPL (doğrula) | En yaygın | C++ ve sanal sürücü mimarisi; sürücüsüz yaklaşım geldiği için bu yol benim değerlendirmemle geride kalıyor |
| D. Sıfırdan | Tamamen senin | En temiz | En yavaş; Core Audio ayrıntılarını baştan öğrenirsin |

**Önerilen yol**

1. Fabar ve FineTune’u indirip derle (1 gün). Beş kriterle değerlendir: uygulama bazlı sesin kendi Mac’inde kararlılığı, kodun okunabilirliği ve testleri, son commit/issue hareketi, ses motorunun arayüzden ayrılabilirliği, lisans uyumu.
2. Fabar uygunsa: klonla, kendi GitHub hesabında **yeni bir repo** olarak yayımla (ClearMix). Upstream’i ayrı remote olarak sakla, LICENSE ve telif notunu koru, README’de kaynağı belirt.
3. GitHub’daki “Fork” butonu yerine yeni repo tercih et: proje senin adında ve bağımsız görünür, geçmiş de korunur. Bu, ileride Codex for OSS başvurusunda birincil bakımcı olduğunu göstermeyi kolaylaştırır.
4. FineTune kodunu kopyalama (GPL). Fikirlerine ve mimarisine bak, kendi kodunu yaz. Eğer GPLv3’ü kabul ediyorsan (BlackHole da GPL) FineTune’u fork etmek seni EQ ve yönlendirmeye hazır götürür; bu bilinçli bir takas olur.

## 4. Mimari

```
SİSTEM SESLERİ (Mikser)
 Uygulama sesi ─▶ Process Tap ─▶ Gain / Mute / EQ ─▶ Seçili çıkış cihazı
 (Spotify, Chrome…)                                    (hoparlör, kulaklık)

MİKROFON (Temizleyici)
 Mikrofon ─▶ Giriş AudioUnit ─▶ Halka tampon ─▶ 48 kHz mono ─▶ RNNoise
          ─▶ Güç karışımı + kapı ─▶ BlackHole 2ch ─▶ Discord / Zoom / OBS
```

**Bileşenler**

- **ClearMixCore:** Arayüzden bağımsız Swift paketi. Tüm ses işleri burada; birim testlenebilir.
- **Mikser motoru:** Uygulama başına tap, kazanç/mute/limitör, çıkış cihazı yönlendirme, seviye ölçerler.
- **Mikrofon motoru:** Giriş yakalama, yeniden örnekleme, RNNoise, kapı, BlackHole’a yazma.
- **Arayüz:** SwiftUI + AppKit (NSStatusItem, popover).
- **Ayarlar:** Uygulama ve profil bazlı ayarlar JSON olarak saklanır.

**Teknik notlar**

- RNNoise 48 kHz’de 10 ms’lik (480 örnek) çerçevelerle çalışır; tüm mikrofon hattı bu çerçeveye göre tasarlanmalı.
- Gecikme hedefi uçtan uca 40 ms altı; ölçülerek doğrulanmalı.
- Mikrofon ve BlackHole farklı saatlerle çalışır. Halka tampon doluluğu izlenip hafif yeniden örnekleme ile kayma düzeltilmeli.
- RNNoise sürekli gürültüde (fan, uğultu) iyidir; klavye tıkırtısı gibi ani seslerde zayıftır. Bu yüzden gürültü kapısıyla birleştirilir. Krisp seviyesinde sonuç vaat etme.
- ⭐ **Alternatif motorlar:** Apple’ın yerleşik ses işleme birimi (Voice Processing I/O; gürültü + yankı iptali, hoparlör kullananlar için) ve ileride DeepFilterNet. “Motor” ayarı olarak sunulabilir; ikisini de lisans/uygunluk açısından doğrula.

**Gerçek zamanlı ses iş parçacığı kuralları (AI’ya yazdırırken kritik)**

- Render callback’inde bellek ayırma, mutex, print, dosya G/Ç, `Task` başlatma yok.
- Tüm tamponlar önceden ayrılır; iş parçacıkları arası veri tek üreticili/tek tüketicili kilitsiz halka tamponla taşınır.
- Callback’te Swift dizi/String işlemleri ve retain/release trafiği yok; ham pointer ve Accelerate (vDSP) kullan.
- RNNoise bağlantı katmanını küçük bir C hedefi olarak yaz, Swift’ten çağır.

## 5. Kapsam (tam sürüm)

Hiçbir özellik çıkarılmadı; sütun yalnızca hangi sürümde geleceğini gösterir.

| Özellik | Sürüm |
| --- | --- |
| **Mikser** |  |
| Uygulama bazlı ses kaydırıcısı ve sessize alma | v0.1 |
| Sadece ses çalan uygulamaları göster, canlı seviye ölçer | v0.1 |
| Uygulama bazlı çıkış cihazı seçimi | v0.5 |
| Ses yükseltme (%200–400, limitörle bozulmayı önle) | v0.5 |
| Ana ses ve çıkış cihazı değiştirme, Bluetooth kulaklık | v0.5 |
| Uygulama başına ayarı hatırlama | v0.5 |
| Uygulama bazlı 10 bant EQ + ön ayarlar | v1.0 |
| Global kısayollar | v1.0 |
| **Mikrofon** |  |
| Mikrofon seçimi, temizleme aç/kapat, güç kaydırıcısı | v0.1 |
| Canlı giriş ölçer, önce/sonra (A/B) dinleme | v0.5 |
| Gürültü kapısı (ses algılama eşiği) | v0.5 |
| Kendini dinleme (monitor) | v0.5 |
| Cihaz çıkınca otomatik geri dönüş / yeniden bağlanma | v0.5 |
| ⭐ Motor seçimi (RNNoise / Apple / DeepFilterNet) | v1.x |
| **Deneyim** |  |
| Menü çubuğu popover, açık/koyu tema | v0.1 |
| Kurulum sihirbazı: izinler, BlackHole kontrolü, “Discord’a ekle” adımı | v0.5 |
| Oturum açılışında başlat | v0.5 |
| ⭐ Profiller (Oyun / Yayın / Toplantı) tek tıkla | v1.0 |
| ⭐ Otomatik kısma (ducking): Discord konuşunca müziği kıs | v1.0 |
| ⭐ “Sorun gider” düğmesi ve tanılama dışa aktarma | v1.0 |
| Türkçe + İngilizce arayüz | v1.0 |
| Otomatik güncelleme (Sparkle) | v1.0 |
| Tamamen yerel çalışma, telemetri yok | Hepsi |

## 6. Tasarım: sezgisel, şık, hızlı

**İlkeler**

- Her şey en fazla 2 tıkla. Ayar ormanı yok; varsayılanlar işe yarar durumda gelir.
- Tek vurgu rengi, sistem yazı tipi (SF Pro), SF Symbols, yerel macOS malzemeleri (vibrancy). Açık/koyu tema otomatik.
- Menü çubuğu simgesi durumu anlatır: kapalı, temizleme aktif, mikrofon sessiz.
- Kaydırıcıya çift tık: %100’e sıfırla. Fare tekerleğiyle ayar. Satıra sağ tık: çıkış cihazı, EQ, sabitle.
- Hata durumları çözüm düğmesiyle gelir: “BlackHole bulunamadı → \[Nasıl kurulur\]”.
- Erişilebilirlik: VoiceOver etiketleri, klavye ile kullanım, “hareketi azalt” desteği.
- Hız hedefleri (ölçülecek): açılış 1 sn altı, boşta CPU %1 civarı, bellek \~60 MB altı, seviye ölçerler yalnızca popover açıkken çizilir.

**Sesler sekmesi**

```
┌──────────────────────────────────────────┐
│ ◐ ClearMix        [ Sesler | Mikrofon ] ⚙ │
├──────────────────────────────────────────┤
│ ♫ Spotify   ▁▃▅  ───●──────  72%  🔇  ▾ │
│ ◎ Discord   ▁▁▂  ──────●───  90%  🔇  ▾ │
│ ◍ Chrome    ▁▁▁  ──●───────  35%  🔇  ▾ │
├──────────────────────────────────────────┤
│ Çıkış: AirPods Pro ▾         Ana ses ───● │
└──────────────────────────────────────────┘
```

**Mikrofon sekmesi**

```
┌──────────────────────────────────────────┐
│ Mikrofon: MacBook Mikrofonu ▾            │
│ ┌──────────────────────────────────────┐ │
│ │ Gürültü Temizleme            [ AÇIK ] │ │
│ │ Güç   ─────────●────   80%           │ │
│ │ Önce ▁▂▅▂▁▁▂     Sonra ▁▁▅▁▁▁▁       │ │
│ │ [ A/B dinle ]  [ Kendimi duy ]        │ │
│ └──────────────────────────────────────┘ │
│ ✓ Discord’a hazır: giriş cihazı olarak   │
│   “BlackHole 2ch” seç                    │
└──────────────────────────────────────────┘
```

**İlk açılış sihirbazı (3 adım):** izinler (mikrofon, sistem sesi) → BlackHole kontrolü → “Discord’da giriş cihazını seç” kılavuzu ve test sesi.

## 7. Teknik yığın

| Katman | Seçim | Neden |
| --- | --- | --- |
| Dil / arayüz | Swift 6 + SwiftUI, AppKit menü çubuğu | Yerel görünüm, küçük kaplama |
| Uygulama sesi | Core Audio process tap + aggregate device | Sürücü gerektirmez (Fabar’ın yaklaşımı) |
| Mikrofon | Core Audio / AUHAL giriş | Düşük gecikme, tam kontrol |
| Gürültü modeli | RNNoise (C, BSD tipi lisans) | Hafif, gerçek zamanlı |
| Sanal mikrofon | BlackHole 2ch (bağımlılık) | Kendi HAL sürücüsünü yazmak çok zor |
| DSP | Accelerate / vDSP | Hızlı ve enerji dostu |
| Güncelleme | Sparkle | Standart |
| Dağıtım | GitHub Releases + Homebrew cask | Kolay kurulum |

Neden Tauri/Rust değil: bu uygulama Core Audio ve menü çubuğuna yakın yaşıyor; yerel Swift hem görünümü hem sistem erişimini kolaylaştırır. Rust (cpal) ses tarafında olur ama arayüz hissi daha az yerel kalır.

**Minimum macOS:** Fabar tabanıyla 14.4+ ile başla; hedef sürümü Bölüm 12’deki kontrolle kesinleştir.

**Dağıtım:** İmzalı + notarize edilmiş uygulama kullanıcı deneyimini çok iyileştirir; imzasız olursa Gatekeeper uyarısı ve manuel izin gerekir. İmzalama için ücretli Apple Developer üyeliği gerekir (güncel ücreti kontrol et).

## 8. Yol haritası

Haftalar, akşam/hafta sonu temposuna göre kaba tahmindir.

- **Faz 0 – Keşif (1–2 gün):** Fabar ve FineTune’u derle, kodu oku, fork kararını ver, doğrulama listesini (Bölüm 12) bitir. *Bitti sayılır:* karar notu repo’da.
- **Faz 1 – Mikrofon prototipi (hafta 1):** Küçük komut satırı aracı: mikrofon → RNNoise → BlackHole. Kayıt alıp önce/sonra karşılaştır, gecikmeyi ölç. *Bitti sayılır:* Discord’da temiz ses duyuluyor, 10 dakikada çıtırtı yok.
- **Faz 2 – Mikser çekirdeği (hafta 2):** Temel koddan uygulama bazlı ses, mute, çıkış yönlendirme, seviye ölçer. *Bitti sayılır:* v0.1 etiketi.
- **Faz 3 – Birleşik arayüz ve sihirbaz (hafta 3):** İki motor tek popover’da, kurulum sihirbazı, cihaz çıkarma/takma dayanıklılığı. *Bitti sayılır:* v0.5.
- **Faz 4 – Cila ve eklentiler (hafta 4–5):** EQ, kısayollar, profiller, ducking, tanılama, yerelleştirme. *Bitti sayılır:* v1.0 adayı.
- **Faz 5 – Yayın (hafta 5–6):** İmzalama, notarization, Sparkle, Homebrew cask, README + tanıtım GIF’i, web sayfası.

## 9. Vibe coding çalışma planı

- Repo köküne bir **AGENTS.md** koy: Bölüm 4’teki gerçek zamanlı kurallar, mimari özeti, “her değişiklik küçük ve testli” kuralı.
- AI’ya tek seferde “hepsini yaz” deme. Sırayla: halka tampon → yeniden örnekleyici → RNNoise sarmalayıcı → mikrofon hattı → mikser. Her parçada testi önce yazdır.
- **Ses test düzeneği:** WAV girdi → işlemci → WAV çıktı komut satırı aracı. Çıktıyı dinle, SNR ölç, altın dosyalarla karşılaştır. Çıtırtıyı AI duyamaz; kayıt ve dalga formu senin gözün olur.
- **Birim testleri:** halka tampon, yeniden örnekleme, kazanç/limitör, kapı mantığı.
- **Elle test listesi:** Bluetooth takıp çıkarma, uyku/uyanma, örnekleme hızı değişimi (44,1 ↔ 48 kHz), Discord ile uçtan uca.
- **CI:** GitHub Actions macOS runner’ında derleme + testler + SwiftLint/SwiftFormat. CI’da ses donanımı yok; donanım testleri elle kalır.
- Kod incelemesinde her PR’da şunu sor: callback’te ayırma/kilit var mı?

## 10. Repo düzeni ve Codex for OSS başvurusu

**Repo:** README (GIF’li, 3 adımda kurulum), LICENSE, CONTRIBUTING, issue/PR şablonları, CHANGELOG, “good first issue” etiketleri, CI rozeti, Türkçe + İngilizce dokümantasyon, düzenli sürümler.

**Başvuru zamanlaması:** Program kullanımı anlamlı, aktif projelere bakıyor ve form birincil/çekirdek bakımcı olduğunu ve herkese açık bir GitHub reposunu istiyor. En sağlam yol: v1.0’ı yayımla, birkaç ay kullanıcı, issue ve PR geçmişi biriktir, sonra başvur. Başvuruda Codex’i nerede kullanacağını net yaz: PR inceleme, sürüm otomasyonu, ses kodunda güvenlik incelemesi. Programın şu an başvuru alıp almadığını ben doğrulayamadım; formu kendin kontrol et.

## 11. Riskler ve önlemler

| Risk | Önlem |
| --- | --- |
| macOS güncellemesi tap/ses davranışını bozar | Sürüm matrisiyle test, beta macOS’ta erken deneme, hataları tanılama çıktısıyla topla |
| Çıtırtı, gecikme, saat kayması | Kilitsiz tampon, kayma düzeltme, ölçüm odaklı geliştirme |
| BlackHole kurulum sürtünmesi | Sihirbazda net yönlendirme; ileride özel adlı sanal cihaz değerlendirmesi |
| Bluetooth kulaklık mikrofonu açılınca ses kalitesi düşer (bilinen macOS davranışı) | Önerilen kurulumda dahili/USB mikrofon + Bluetooth kulaklık çıkışı; sihirbazda ipucu |
| RNNoise beklentiyi karşılamaz (özellikle ani sesler) | Kapı + güç ayarı, dürüst README, ileride alternatif motorlar |
| Lisans karışıklığı (MIT / GPL) | Fork kararını erken ver, GPL koddan kopyalama, THIRD\_PARTY.md tut |
| İsim çakışması | Başlamadan GitHub ve marka araması |

## 12. Başlamadan önce doğrulanacaklar

- [ ] Fabar: son commit tarihi, açık issue’lar, test var mı, kod yapısı temiz mi
- [ ] FineTune’un minimum macOS sürümü (kaynaklar 14.2 ve 15+ diyor)
- [ ] BlackHole ve Background Music lisansları
- [ ] Process tap API’sinin hedef macOS sürümü ve gerekli izin anahtarları (mikrofon + sistem ses kaydı)
- [ ] DeepFilterNet ve Apple Voice Processing I/O uygunluğu
- [ ] “ClearMix” adının GitHub/marka çakışması
- [ ] Apple Developer üyeliği ve güncel ücreti
- [ ] Codex for OSS formunun açık olduğu

## 13. İlk gün

1. Fabar ve FineTune’u klonla ve derle.
2. Her ikisinde de Spotify + tarayıcı ile uygulama bazlı sesi dene; 30 dakika çalıştırıp kararlılığa bak.
3. Kod yapısını oku: ses motoru arayüzden ayrılabiliyor mu?
4. 5 kriterlik karar notunu yaz, fork kararını ver.
5. Yeni repoyu aç, LICENSE ve AGENTS.md’yi ekle, CI’ı kur.

## Kaynaklar

- Fabar: github.com/gigaptera/fabar
- FineTune: github.com/ronitsingh10/FineTune
- Background Music: github.com/kyleneideck/BackgroundMusic
- eqMac: github.com/bitgapp/eqMac
- BlackHole: github.com/ExistentialAudio/BlackHole
- RNNoise: github.com/xiph/rnnoise
- Crispy (RNNoise + BlackHole örneği): github.com/sleep3r/crispy
- Aurio (ticari örnek): aurio.dev
- Codex for OSS: openai.com/form/codex-for-oss
