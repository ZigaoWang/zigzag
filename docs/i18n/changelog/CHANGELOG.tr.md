# Değişiklik Günlüğü

Bunlar Zigzag’in CHANGELOG.md’den çevrilen Türkçe sürüm notlarıdır. Uygulama, kullandığınız sürümün notlarını gösterir; tüm sürümler [zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) adresindedir. 0.10.0’dan önceki sürümler [CHANGELOG.md](../../../CHANGELOG.md) dosyasında İngilizcedir.

## [Unreleased]

## [0.10.0] - 2026-11-25

Japonca ve Koreceden Almanca, Fransızca, İspanyolca ve Rusçaya kadar on üç yeni dilde Zigzag; kaydedilen dosyayı devreden indirme kuralları; en son ne zaman güncellendiğini gösteren canlı klasörler; ve Çince Pinyin yazarken İngilizceye geçince fazladan boşluk kalmaması.

### Yeni Özellikler
- Zigzag artık Japonca; Apple’ın macOS ve Safari için kullandığı Japonca terimleri izler. Mac’inizin dilini kullanır veya dili Ayarlar › Genel › Dil bölümünden seçebilirsiniz.
- Zigzag artık Korece, Almanca, Fransızca, İtalyanca, İspanyolca, Brezilya Portekizcesi, Rusça, Felemenkçe, Lehçe ve Türkçe; her dilde Apple’ın kendi terimlerini izler. Mac’inizin dilini kullanır veya Ayarlar › Genel › Dil bölümünden bir dil seçebilirsiniz.
- Bir indirme kuralı adres yerine dosyayı devredebilir: “Devret” seçeneğini “Dosya” yapın; Zigzag dosyayı önce sayfanın oturumuyla indirir, sonra kaydedilen dosyayı uygulamaya, betiğe veya hizmete verir. Bağlantılar yine adreslerini devreder; dosya devreden bir kuralın şablonları kaydedilen dosya için {file} veya {file_url} kullanabilir. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#529](https://github.com/ZigaoWang/zigzag/issues/529))
- Canlı klasörün menüsü artık en son ne zaman güncellendiğiyle başlar; örneğin “Güncellenme: 5 dakika önce” veya getirilirken “Güncelleniyor…”.
- “Yeni Canlı Klasör” ve “Canlı Klasörü Düzenle” penceresi önce kaynağı sorar, menülerini alanlarla hizalar ve altlarında klasörün ne göstereceğini ve her 30 dakikada bir (Düşük Güç Modunda saatte bir) denetlendiğini söyler. Boş bırakılan ad, klasörün alacağı adı gösterir; GitHub’ın kabul etmeyeceği bir kullanıcı adı işaretlenir.

### Düzeltmeler
- Zigzag Mini bir sayfanın üzerinde açıkken karartılmış sayfada kaydırmak artık arkadaki sayfayı kaydırmaz. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#531](https://github.com/ZigaoWang/zigzag/pull/531))
- Web sitelerinin bu Mac’teki uygulamalara erişmesinden önceki açıklama artık adımları sırasıyla söyler: önce ayarı açın, sonra her siteyi kendi “Site Ayarları” bölümünden açın; ayarı kapatmak tüm siteleri durdurur. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#533](https://github.com/ZigaoWang/zigzag/issues/533))
- Ayarlar’da, yanında düğmeler veya arama alanı olan bir başlığın altındaki liste, örneğin “Web Sitelerinin Sakladıkları” veya “İndirmeleri ve Bağlantıları Devret”, artık bu denetimlerin hemen altından başlamaz. Altlarında diğer tüm başlıklardaki kadar boşluk bırakır. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#527](https://github.com/ZigaoWang/zigzag/issues/527))
- Bir sözcüğün ortasında Çince Pinyin’den İngilizceye geçmek, Chrome’daki gibi, artık sayfada veya adres çubuğunda harflerin arasında boşluk bırakmaz.
- “Şeffaf” camlı, arkası görünen bir Space, Zigzag boşta dururken, boş bir sayfada veya Ayarlar’da bile artık Mac’in grafik işlemcisini meşgul etmez. macOS her karede tüm pencereyi ve gölgesini yeniden çiziyordu; artık yalnızca bir şey değiştiğinde çiziyor. Güncelleme kartının ilerleme çubuğu da gizliyken kaymayı bırakır.
