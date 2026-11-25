# Değişiklik Günlüğü

Bunlar Zigzag’in CHANGELOG.md’den çevrilen Türkçe sürüm notlarıdır. Uygulama, kullandığınız sürümün notlarını gösterir; tüm sürümler [zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) adresindedir. 0.10.0’dan önceki sürümler [CHANGELOG.md](../../../CHANGELOG.md) dosyasında İngilizcedir.

## [Unreleased]

### Yeni Özellikler
- Geçmişteki arama aksanları ve harf büyüklüğünü yok sayar, her sözcüğü herhangi bir sırada bulup işaretler ve hiçbir eşleşmeyi bir yığının içinde gizlemez; günün her bölümünün tek bir başlığı vardır, aynı siteden iki sayfa iki satır olarak kalır ve liste ok tuşlarına, Sil’e, ⌘Return’e, ⌘F’ye ve bir sitenin tamamını kaldıran sağ tıklamaya yanıt verir.
- Canlı klasör yeni sayfaları denetlerken simgesindeki rozet, Mail’in denetlenen bir posta kutusunu gösterdiği gibi dönen bir halka gösterir ve denetim biter bitmez durur.
- “Yeni Canlı Klasör” ve “Canlı Klasörü Düzenle” penceresi klasörün simgesini kenar çubuğundaki gibi gösterir: GitHub listesi için GitHub’ınkini, akış için sitenin simgesini veya seçtiğiniz simgeyi. Simgeyi “Simgeyi Değiştir…” ile olduğu gibi değiştirmek için üzerine tıklayın; yeni klasör seçtiğiniz simgeyi korur.

### Değişiklikler
- İki parmakla geri ve ileri kaydırmalar daha akıcıdır, daha kısa bir mesafede veya daha hafif bir fırlatmada çalışır, sayfanın yukarı aşağı kaymasını önler ve sekmelerde, Bölünmüş Görünümde ve Zigzag Mini’de oku ekranda veya sayfayı kaymış halde bırakmaz.

### Düzeltmeler
- Adres çubuğu sayfanın üstündeyken ve Space saydamken, oynatılan bir video artık Mac’in grafiklerini çubuk kapalıyken olduğundan çok daha fazla meşgul etmez. Pencerenin camı artık tüm pencerenin değil, kenar çubuğunun arkasında kalır.
- Düşük bellekli Mac’te saatlerce uykuya alınmış bir sekme artık Azure DevOps ve Microsoft 365 gibi sitelerde giriş yapılmamış olarak uyanmaz: giriş çerezlerini tutan WebKit parçası, macOS’un bellek azken yapabileceği gibi durursa Zigzag onları sayfa yüklenmeden önce geri koyar. ([#502](https://github.com/ZigaoWang/zigzag/issues/502))
- Tam ekrandaki bir video artık Bilibili’de olduğu gibi sitenin kendi üst çubuğu veya yan sütunuyla örtülmez. ([#543](https://github.com/ZigaoWang/zigzag/issues/543))
- Geri, ileri ve yeniden yükle artık pencere düğmeleri gösterilmeyen yerde, örneğin menü çubuğu inmeden önceki tam ekranda, boş yer bırakmaz; daha kısa kayan kenar çubuğu açıkken de pencere düğmeleri çubukta kalır. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#542](https://github.com/ZigaoWang/zigzag/issues/542))
- Güncellenirken açık bırakılan canlı klasör menüsü artık kapanmadan “Güncelleniyor…” durumundan “Az Önce Güncellendi” durumuna veya neden yenilenemediğine geçer.
- Satır başına favori Otomatik olduğunda favoriler satırlara eşit dağılır: dördün sığacağı yerde altı favori, dört ve iki değil, üçer favorilik iki satır olur.

## [0.10.0] - 2026-11-25

Japonca ve Koreceden Almanca, Fransızca, İspanyolca ve Rusçaya kadar on üç yeni dilde Zigzag; kaydedilen dosyayı devreden indirme kuralları; en son ne zaman güncellendiğini gösteren canlı klasörler; ve Çince Pinyin yazarken İngilizceye geçince fazladan boşluk kalmaması.

### Yeni Özellikler
- Zigzag artık Japonca; Apple’ın macOS ve Safari için kullandığı Japonca terimleri izler. Mac’inizin dilini kullanır veya dili Ayarlar › Genel › Dil bölümünden seçebilirsiniz.
- Zigzag artık Korece, Almanca, Fransızca, İtalyanca, İspanyolca, Brezilya Portekizcesi, Rusça, Felemenkçe, Lehçe ve Türkçe; her dilde Apple’ın kendi terimlerini izler. Mac’inizin dilini kullanır veya Ayarlar › Genel › Dil bölümünden bir dil seçebilirsiniz.
- Bir indirme kuralı adres yerine dosyayı devredebilir: “Devret” seçeneğini “Dosya” yapın; Zigzag dosyayı önce sayfanın oturumuyla indirir, sonra kaydedilen dosyayı uygulamaya, betiğe veya hizmete verir. Bağlantılar yine adreslerini devreder; dosya devreden bir kuralın şablonları kaydedilen dosya için {file} veya {file_url} kullanabilir. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#529](https://github.com/ZigaoWang/zigzag/issues/529))
- Canlı klasörün menüsü artık en son ne zaman güncellendiğiyle başlar; örneğin “Güncellenme: 5 dakika önce” veya getirilirken “Güncelleniyor…”.
- “Yeni Canlı Klasör” ve “Canlı Klasörü Düzenle” penceresi önce kaynağı sorar, menülerini alanlarla hizalar ve altlarında klasörün ne göstereceğini ve her 30 dakikada bir (Düşük Güç Modunda saatte bir) denetlendiğini söyler. Boş bırakılan ad, klasörün alacağı adı gösterir; GitHub’ın kabul etmeyeceği bir kullanıcı adı işaretlenir.
- Site Ayarları’nda, düzgün çalışmayan bir site için uyumluluk modu: tek bir anahtar o sitede genişletmeleri, reklam engellemeyi, çerez uyarılarını ve gizlenen öğeleri kapatır; kapattığınızda bunlar için yaptığınız tüm seçimler geri gelir. Açıkken Site Ayarları vurgu renginde görünür ve Ayarlar › Gizlilik › Siteler onu listeler. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#497](https://github.com/ZigaoWang/zigzag/issues/497))
- Ayarlar › Görünüm › Üzerine gelince bağlantı adresini göster: kapatırsanız bir bağlantıyı gösterirken sayfanın köşesinde çubuk görünmez; tarayıcı pencerelerinde, Zigzag Mini’de, web uygulamalarında ve sekme genel görünümünde böyledir. Siz kapatana kadar açık kalır. Teşekkürler: [sarekhamri](https://github.com/sarekhamri). ([#537](https://github.com/ZigaoWang/zigzag/issues/537))
- Ayarlar › Görünüm › Daha kısa yüzen kenar çubuğu: kenar çubuğu gizliyken sayfanın üzerine çıkan kenar çubuğu pencere yüksekliğinin üçte ikisi kadar olur, altında ve üstünde altıda bir boşluk kalır. Yerleşik kenar çubuğu değişmez. Siz açana kadar kapalıdır. Teşekkürler: [sarekhamri](https://github.com/sarekhamri). ([#538](https://github.com/ZigaoWang/zigzag/issues/538))
- Ayarlar › Görünüm › Sabitlenmiş sekmeler kutucuk olarak: klasörlerin dışındaki sabitlenmiş sekmeler favorilerinizin altında kutucuk olarak görünür; aynı ızgarada, aralarında ince bir çizgiyle durur ve satırları gibi açılır, bellekten kaldırılır, menüsünü gösterir ve sürüklenir. Klasörler ve sayfaları satır olarak kalır. Siz açana kadar kapalıdır. Teşekkürler: [sarekhamri](https://github.com/sarekhamri). ([#539](https://github.com/ZigaoWang/zigzag/issues/539))
- Ayarlar’da uzun listeler artık Site İzinleri gibi kutular içinde katlanır: Kısayollar’daki her menü, kaydedilen yanıtları içinde taşıyan her indirme kuralı, her tür özellik bayrağı ve üçten fazla öğe listeleyen Geliştirici Modundaki Siteler, Güvenilen Sertifikalar ve Sayfa Boyutları. Bir ayar bul, eşleşmenin olduğu kutuyu yine açar. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#536](https://github.com/ZigaoWang/zigzag/issues/536))
- Site İzinleri’nin kendi araması ve Bir ayar bul artık siteleri izne ve seçime göre de bulur: kamera, bildirimler veya engelle yazın; o seçimin yapıldığı her site, kendi site adının altında görünür. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#532](https://github.com/ZigaoWang/zigzag/issues/532))

### Düzeltmeler
- Zigzag Mini bir sayfanın üzerinde açıkken karartılmış sayfada kaydırmak artık arkadaki sayfayı kaydırmaz. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#531](https://github.com/ZigaoWang/zigzag/pull/531))
- Web sitelerinin bu Mac’teki uygulamalara erişmesinden önceki açıklama artık adımları sırasıyla söyler: önce ayarı açın, sonra her siteyi kendi “Site Ayarları” bölümünden açın; ayarı kapatmak tüm siteleri durdurur. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#533](https://github.com/ZigaoWang/zigzag/issues/533))
- Ayarlar’da, yanında düğmeler veya arama alanı olan bir başlığın altındaki liste, örneğin “Web Sitelerinin Sakladıkları” veya “İndirmeleri ve Bağlantıları Devret”, artık bu denetimlerin hemen altından başlamaz. Altlarında diğer tüm başlıklardaki kadar boşluk bırakır. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#527](https://github.com/ZigaoWang/zigzag/issues/527))
- Bir sözcüğün ortasında Çince Pinyin’den İngilizceye geçmek, Chrome’daki gibi, artık sayfada veya adres çubuğunda harflerin arasında boşluk bırakmaz.
- “Şeffaf” camlı, arkası görünen bir Space, Zigzag boşta dururken, boş bir sayfada veya Ayarlar’da bile artık Mac’in grafik işlemcisini meşgul etmez. macOS her karede tüm pencereyi ve gölgesini yeniden çiziyordu; artık yalnızca bir şey değiştiğinde çiziyor. Güncelleme kartının ilerleme çubuğu da gizliyken kaymayı bırakır.
- Ayarlar daha hızlı açılıyor. Bir bölümün satırları ilk açıldığında, katlanmış bir kutunun satırları ise kutu açıldığında veya bir arama içine baktığında oluşturulur; bu yüzden Ayarlar’ı Genel’de açmak artık İndirilenler’i, Kısayollar’ı ya da Geliştirici’yi oluşturmaz. Teşekkürler: [Lakeland97](https://github.com/Lakeland97). ([#536](https://github.com/ZigaoWang/zigzag/issues/536))
- Bitwarden’ın “Biyometri ile kilidi aç” seçeneği artık Bitwarden uygulamasına ulaşıyor. Zigzag, Bitwarden’a uygulamayla zaten konuşabildiğini söylemişti; bu yüzden Bitwarden hiç sormuyordu, sonra da Zigzag onu uygulamadan uzak tutuyordu. Artık Bitwarden soruyor ve Zigzag size buna izin verip vermeyeceğinizi soruyor. Biyometriyi daha önce açtıysanız Bitwarden’ın ayarlarında “Biyometri ile kilidi aç” seçeneğini kapatıp yeniden açın. Teşekkürler: [retorquere](https://github.com/retorquere). ([#484](https://github.com/ZigaoWang/zigzag/issues/484))
