var ae=Object.defineProperty;var O=(s,e)=>{for(var i in e)ae(s,i,{get:e[i],enumerable:!0})};var oe={};O(oe,{CspEvaluator:()=>k,DEFAULT_CHECKS:()=>ne,STRICTCSP_CHECKS:()=>ke});var c=class s{constructor(e,i,t,o,n){this.type=e;this.description=i;this.severity=t;this.directive=o;this.value=n}type;description;severity;directive;value;static getHighestSeverity(e){if(e.length===0)return 100;let i=e.map(o=>o.severity),t=(o,n)=>o<n?o:n;return i.reduce(t,100)}equals(e){return e instanceof s?e.type===this.type&&e.description===this.description&&e.severity===this.severity&&e.directive===this.directive&&e.value===this.value:!1}};var f=class s{directives={};clone(){let e=new s;for(let[i,t]of Object.entries(this.directives))t&&(e.directives[i]=[...t]);return e}convertToString(){let e="";for(let[i,t]of Object.entries(this.directives)){if(e+=i,t!==void 0)for(let o,n=0;o=t[n];n++)e+=" ",e+=o;e+="; "}return e}getEffectiveCsp(e,i){let t=i||[],o=this.clone(),n=o.getEffectiveDirective("script-src"),l=this.directives[n]||[],a=o.directives[n];if(a&&(o.policyHasScriptNonces()||o.policyHasScriptHashes()))if(e>=2)l.includes("'unsafe-inline'")&&(_(a,"'unsafe-inline'"),t.push(new c(405,"unsafe-inline is ignored if a nonce or a hash is present. (CSP2 and above)",100,n,"'unsafe-inline'")));else for(let u of l)(u.startsWith("'nonce-")||u.startsWith("'sha"))&&_(a,u);if(a&&this.policyHasStrictDynamic())if(e>=3)for(let u of l)(!u.startsWith("'")||u==="'self'"||u==="'unsafe-inline'")&&(_(a,u),t.push(new c(405,"Because of strict-dynamic this entry is ignored in CSP3 and above",100,n,u)));else _(a,"'strict-dynamic'");return e<3&&(delete o.directives["report-to"],delete o.directives["worker-src"],delete o.directives["manifest-src"],delete o.directives["trusted-types"],delete o.directives["require-trusted-types-for"]),o}getEffectiveDirective(e){return!(e in this.directives)&&le.includes(e)?"default-src":e}getEffectiveDirectives(e){return[...new Set(e.map(t=>this.getEffectiveDirective(t)))]}policyHasScriptNonces(){let e=this.getEffectiveDirective("script-src");return(this.directives[e]||[]).some(t=>E(t))}policyHasScriptHashes(){let e=this.getEffectiveDirective("script-src");return(this.directives[e]||[]).some(t=>b(t))}policyHasStrictDynamic(){let e=this.getEffectiveDirective("script-src");return(this.directives[e]||[]).includes("'strict-dynamic'")}},m=(d=>(d.SELF="'self'",d.NONE="'none'",d.UNSAFE_INLINE="'unsafe-inline'",d.UNSAFE_EVAL="'unsafe-eval'",d.WASM_EVAL="'wasm-eval'",d.WASM_UNSAFE_EVAL="'wasm-unsafe-eval'",d.STRICT_DYNAMIC="'strict-dynamic'",d.UNSAFE_HASHED_ATTRIBUTES="'unsafe-hashed-attributes'",d.UNSAFE_HASHES="'unsafe-hashes'",d.REPORT_SAMPLE="'report-sample'",d.BLOCK="'block'",d.ALLOW="'allow'",d))(m||{});var h=(r=>(r.CHILD_SRC="child-src",r.CONNECT_SRC="connect-src",r.DEFAULT_SRC="default-src",r.FONT_SRC="font-src",r.FRAME_SRC="frame-src",r.IMG_SRC="img-src",r.MEDIA_SRC="media-src",r.OBJECT_SRC="object-src",r.SCRIPT_SRC="script-src",r.SCRIPT_SRC_ATTR="script-src-attr",r.SCRIPT_SRC_ELEM="script-src-elem",r.STYLE_SRC="style-src",r.STYLE_SRC_ATTR="style-src-attr",r.STYLE_SRC_ELEM="style-src-elem",r.PREFETCH_SRC="prefetch-src",r.MANIFEST_SRC="manifest-src",r.WORKER_SRC="worker-src",r.BASE_URI="base-uri",r.PLUGIN_TYPES="plugin-types",r.SANDBOX="sandbox",r.DISOWN_OPENER="disown-opener",r.FORM_ACTION="form-action",r.FRAME_ANCESTORS="frame-ancestors",r.NAVIGATE_TO="navigate-to",r.REPORT_TO="report-to",r.REPORT_URI="report-uri",r.BLOCK_ALL_MIXED_CONTENT="block-all-mixed-content",r.UPGRADE_INSECURE_REQUESTS="upgrade-insecure-requests",r.REFLECTED_XSS="reflected-xss",r.REFERRER="referrer",r.REQUIRE_SRI_FOR="require-sri-for",r.TRUSTED_TYPES="trusted-types",r.REQUIRE_TRUSTED_TYPES_FOR="require-trusted-types-for",r.WEBRTC="webrtc",r))(h||{}),le=["child-src","connect-src","default-src","font-src","frame-src","img-src","manifest-src","media-src","object-src","script-src","script-src-attr","script-src-elem","style-src","style-src-attr","style-src-elem","worker-src"];function S(s){return Object.values(h).includes(s)}function R(s){return Object.values(m).includes(s)}function C(s){return new RegExp("^[a-zA-Z][+a-zA-Z0-9.-]*:$").test(s)}var ue=new RegExp("^'nonce-[a-zA-Z0-9+/_-]+[=]{0,2}'$"),pe=new RegExp("^'nonce-(.+)'$");function E(s,e){return(e?ue:pe).test(s)}var de=new RegExp("^'(sha256|sha384|sha512)-[a-zA-Z0-9+/]+[=]{0,2}'$"),me=new RegExp("^'(sha256|sha384|sha512)-(.+)'$");function b(s,e){return(e?de:me).test(s)}function _(s,e){if(s.includes(e)){let i=s.findIndex(t=>e===t);s.splice(i,1)}}function P(s){let e=[];for(let i of Object.keys(s.directives))S(i)||(i.endsWith(":")?e.push(new c(101,"CSP directives don't end with a colon.",20,i)):e.push(new c(101,'Directive "'+i+'" is not a known CSP directive.',20,i)));return e}function F(s){let e=[];for(let[i,t]of Object.entries(s.directives))if(t!==void 0)for(let o of t)S(o)&&e.push(new c(100,'Did you forget the semicolon? "'+o+'" seems to be a directive, not a value.',20,i,o));return e}function L(s){let e=[],i=Object.values(m).map(t=>t.replace(/'/g,""));for(let[t,o]of Object.entries(s.directives))if(o!==void 0)for(let n of o){if(i.some(l=>l===n)||n.startsWith("nonce-")||n.match(/^(sha256|sha384|sha512)-/)){e.push(new c(102,'Did you forget to surround "'+n+'" with single-ticks?',20,t,n));continue}if(n.startsWith("'")){if(t==="require-trusted-types-for"){if(n==="'script'")continue}else if(t==="trusted-types"){if(n==="'allow-duplicates'"||n==="'none'")continue}else if(R(n)||b(n)||E(n))continue;e.push(new c(102,n+" seems to be an invalid CSP keyword.",20,t,n))}}return e}var x=["//gstatic.com/fsn/angular_js-bundle1.js","//www.gstatic.com/fsn/angular_js-bundle1.js","//www.googleadservices.com/pageadimg/imgad","//yandex.st/angularjs/1.2.16/angular-cookies.min.js","//yastatic.net/angularjs/1.2.23/angular.min.js","//yuedust.yuedu.126.net/js/components/angular/angular.js","//art.jobs.netease.com/script/angular.js","//csu-c45.kxcdn.com/angular/angular.js","//elysiumwebsite.s3.amazonaws.com/uploads/blog-media/rockstar/angular.min.js","//inno.blob.core.windows.net/new/libs/AngularJS/1.2.1/angular.min.js","//gift-talk.kakao.com/public/javascripts/angular.min.js","//ajax.googleapis.com/ajax/libs/angularjs/1.2.0rc1/angular-route.min.js","//master-sumok.ru/vendors/angular/angular-cookies.js","//ayicommon-a.akamaihd.net/static/vendor/angular-1.4.2.min.js","//pangxiehaitao.com/framework/angular-1.3.9/angular-animate.min.js","//cdnjs.cloudflare.com/ajax/libs/angular.js/1.2.16/angular.min.js","//96fe3ee995e96e922b6b-d10c35bd0a0de2c718b252bc575fdb73.ssl.cf1.rackcdn.com/angular.js","//oss.maxcdn.com/angularjs/1.2.20/angular.min.js","//reports.zemanta.com/smedia/common/angularjs/1.2.11/angular.js","//cdn.shopify.com/s/files/1/0225/6463/t/1/assets/angular-animate.min.js","//parademanagement.com.s3-website-ap-southeast-1.amazonaws.com/js/angular.min.js","//cdn.jsdelivr.net/angularjs/1.1.2/angular.min.js","//eb2883ede55c53e09fd5-9c145fb03d93709ea57875d307e2d82e.ssl.cf3.rackcdn.com/components/angular-resource.min.js","//andors-trail.googlecode.com/git/AndorsTrailEdit/lib/angular.min.js","//cdn.walkme.com/General/EnvironmentTests/angular/angular.min.js","//laundrymail.com/angular/angular.js","//s3-eu-west-1.amazonaws.com/staticancpa/js/angular-cookies.min.js","//collade.demo.stswp.com/js/vendor/angular.min.js","//mrfishie.github.io/sailor/bower_components/angular/angular.min.js","//askgithub.com/static/js/angular.min.js","//services.amazon.com/solution-providers/assets/vendor/angular-cookies.min.js","//raw.githubusercontent.com/angular/code.angularjs.org/master/1.0.7/angular-resource.js","//prb-resume.appspot.com/bower_components/angular-animate/angular-animate.js","//dl.dropboxusercontent.com/u/30877786/angular.min.js","//static.tumblr.com/x5qdx0r/nPOnngtff/angular-resource.min_1_.js","//storage.googleapis.com/assets-prod.urbansitter.net/us-sym/assets/vendor/angular-sanitize/angular-sanitize.min.js","//twitter.github.io/labella.js/bower_components/angular/angular.min.js","//cdn2-casinoroom.global.ssl.fastly.net/js/lib/angular-animate.min.js","//www.adobe.com/devnet-apps/flashshowcase/lib/angular/angular.1.1.5.min.js","//eternal-sunset.herokuapp.com/bower_components/angular/angular.js","//cdn.bootcss.com/angular.js/1.2.0/angular.min.js"];var y=["//vk.com/swf/video.swf","//ajax.googleapis.com/ajax/libs/yui/2.8.0r4/build/charts/assets/charts.swf"];var j=["googletagmanager.com","www.googletagmanager.com","www.googleadservices.com","google-analytics.com","ssl.google-analytics.com","www.google-analytics.com"],U=["//bebezoo.1688.com/fragment/index.htm","//www.google-analytics.com/gtm/js","//googleads.g.doubleclick.net/pagead/conversion/1036918760/wcm","//www.googleadservices.com/pagead/conversion/1070110417/wcm","//www.google.com/tools/feedback/escalation-options","//pin.aliyun.com/check_audio","//offer.alibaba.com/market/CID100002954/5/fetchKeyword.do","//ccrprod.alipay.com/ccr/arriveTime.json","//group.aliexpress.com/ajaxAcquireGroupbuyProduct.do","//detector.alicdn.com/2.7.3/index.php","//suggest.taobao.com/sug","//translate.google.com/translate_a/l","//count.tbcdn.cn//counter3","//wb.amap.com/channel.php","//translate.googleapis.com/translate_a/l","//afpeng.alimama.com/ex","//accounts.google.com/o/oauth2/revoke","//pagead2.googlesyndication.com/relatedsearch","//yandex.ru/soft/browsers/check","//api.facebook.com/restserver.php","//mts0.googleapis.com/maps/vt","//syndication.twitter.com/widgets/timelines/765840589183213568","//www.youtube.com/profile_style","//googletagmanager.com/gtm/js","//mc.yandex.ru/watch/24306916/1","//share.yandex.net/counter/gpp/","//ok.go.mail.ru/lady_on_lady_recipes_r.json","//d1f69o4buvlrj5.cloudfront.net/__efa_15_1_ornpba.xekq.arg/optout_check","//www.googletagmanager.com/gtm/js","//api.vk.com/method/wall.get","//www.sharethis.com/get-publisher-info.php","//google.ru/maps/vt","//pro.netrox.sc/oapi/h_checksite.ashx","//vimeo.com/api/oembed.json/","//de.blog.newrelic.com/wp-admin/admin-ajax.php","//ajax.googleapis.com/ajax/services/search/news","//ssl.google-analytics.com/gtm/js","//pubsub.pubnub.com/subscribe/demo/hello_world/","//pass.yandex.ua/services","//id.rambler.ru/script/topline_info.js","//m.addthis.com/live/red_lojson/100eng.json","//passport.ngs.ru/ajax/check","//catalog.api.2gis.ru/ads/search","//gum.criteo.com/sync","//maps.google.com/maps/vt","//ynuf.alipay.com/service/um.json","//securepubads.g.doubleclick.net/gampad/ads","//c.tiles.mapbox.com/v3/texastribune.tx-congress-cvap/6/15/26.grid.json","//rexchange.begun.ru/banners","//an.yandex.ru/page/147484","//links.services.disqus.com/api/ping","//api.map.baidu.com/","//tj.gongchang.com/api/keywordrecomm/","//data.gongchang.com/livegrail/","//ulogin.ru/token.php","//beta.gismeteo.ru/api/informer/layout.js/120x240-3/ru/","//maps.googleapis.com/maps/api/js/GeoPhotoService.GetMetadata","//a.config.skype.com/config/v1/Skype/908_1.33.0.111/SkypePersonalization","//maps.beeline.ru/w","//target.ukr.net/","//www.meteoprog.ua/data/weather/informer/Poltava.js","//cdn.syndication.twimg.com/widgets/timelines/599200054310604802","//wslocker.ru/client/user.chk.php","//community.adobe.com/CommunityPod/getJSON","//maps.google.lv/maps/vt","//dev.virtualearth.net/REST/V1/Imagery/Metadata/AerialWithLabels/26.318581","//awaps.yandex.ru/10/8938/02400400.","//a248.e.akamai.net/h5.hulu.com/h5.mp4","//nominatim.openstreetmap.org/","//plugins.mozilla.org/en-us/plugins_list.json","//h.cackle.me/widget/32153/bootstrap","//graph.facebook.com/1/","//fellowes.ugc.bazaarvoice.com/data/reviews.json","//widgets.pinterest.com/v3/pidgets/boards/ciciwin/hedgehog-squirrel-crafts/pins/","//www.linkedin.com/countserv/count/share","//se.wikipedia.org/w/api.php","//cse.google.com/api/007627024705277327428/cse/r3vs7b0fcli/queries/js","//relap.io/api/v2/similar_pages_jsonp.js","//c1n3.hypercomments.com/stream/subscribe","//maps.google.de/maps/vt","//books.google.com/books","//connect.mail.ru/share_count","//tr.indeed.com/m/newjobs","//www-onepick-opensocial.googleusercontent.com/gadgets/proxy","//www.panoramio.com/map/get_panoramas.php","//client.siteheart.com/streamcli/client","//www.facebook.com/restserver.php","//autocomplete.travelpayouts.com/avia","//www.googleapis.com/freebase/v1/topic/m/0344_","//mts1.googleapis.com/mapslt/ft","//api.twitter.com/1/statuses/oembed.json","//fast.wistia.com/embed/medias/o75jtw7654.json","//partner.googleadservices.com/gampad/ads","//pass.yandex.ru/services","//gupiao.baidu.com/stocks/stockbets","//widget.admitad.com/widget/init","//api.instagram.com/v1/tags/partykungen23328/media/recent","//video.media.yql.yahoo.com/v1/video/sapi/streams/063fb76c-6c70-38c5-9bbc-04b7c384de2b","//ib.adnxs.com/jpt","//pass.yandex.com/services","//www.google.de/maps/vt","//clients1.google.com/complete/search","//api.userlike.com/api/chat/slot/proactive/","//www.youku.com/index_cookielist/s/jsonp","//mt1.googleapis.com/mapslt/ft","//api.mixpanel.com/track/","//wpd.b.qq.com/cgi/get_sign.php","//pipes.yahooapis.com/pipes/pipe.run","//gdata.youtube.com/feeds/api/videos/WsJIHN1kNWc","//9.chart.apis.google.com/chart","//cdn.syndication.twitter.com/moments/709229296800440320","//api.flickr.com/services/feeds/photos_friends.gne","//cbks0.googleapis.com/cbk","//www.blogger.com/feeds/5578653387562324002/posts/summary/4427562025302749269","//query.yahooapis.com/v1/public/yql","//kecngantang.blogspot.com/feeds/posts/default/-/Komik","//www.travelpayouts.com/widgets/50f53ce9ada1b54bcc000031.json","//i.cackle.me/widget/32586/bootstrap","//translate.yandex.net/api/v1.5/tr.json/detect","//a.tiles.mapbox.com/v3/zentralmedia.map-n2raeauc.jsonp","//maps.google.ru/maps/vt","//c1n2.hypercomments.com/stream/subscribe","//rec.ydf.yandex.ru/cookie","//cdn.jsdelivr.net"];function g(s){return s=s.replace(/^\w[+\w.-]*:\/\//i,""),s=s.replace(/^\/\//,""),s}function M(s){let e=new URL("https://"+g(s).replace(":*","").replace("*","wildcard_placeholder")).hostname.replace("wildcard_placeholder","*"),i=/^\[[\d:]+\]/;return g(s).match(i)&&!e.match(i)?"["+e+"]":e}function H(s){return s.startsWith("//")?s.replace("//","https://"):s}function I(s,e){let i=new URL(H(s.replace(":*","").replace("*","wildcard_placeholder"))),t=e.map(p=>new URL(H(p))),o=i.hostname.toLowerCase(),n=o.startsWith("wildcard_placeholder."),l=o.replace(/^\wildcard_placeholder/i,""),a=i.pathname,u=a!=="/";for(let p of t){let D=p.hostname;if(D.endsWith(l)&&!(!n&&o!==D)){if(u){if(a.endsWith("/")){if(!p.pathname.startsWith(a))continue}else if(p.pathname!==a)continue}return p}}return null}function w(s,e){let i=Object.keys(s.directives);for(let t of i){let o=s.directives[t];o&&e(t,o)}}var Y=["script-src","object-src","base-uri"],_e=["data:","http:","https:"];function W(s){let e=s.getEffectiveDirective("script-src");return(s.directives[e]||[]).includes("'unsafe-inline'")?[new c(301,"'unsafe-inline' allows the execution of unsafe in-page scripts and event handlers.",10,e,"'unsafe-inline'")]:[]}function B(s){let e=s.getEffectiveDirective("script-src");return(s.directives[e]||[]).includes("'unsafe-eval'")?[new c(302,"'unsafe-eval' allows the execution of code injected into DOM APIs such as eval().",50,e,"'unsafe-eval'")]:[]}function V(s){let e=[],i=s.getEffectiveDirectives(Y);for(let t of i){let o=s.directives[t]||[];for(let n of o)_e.includes(n)&&e.push(new c(303,n+" URI in "+t+" allows the execution of unsafe scripts.",10,t,n))}return e}function G(s){let e=[],i=s.getEffectiveDirectives(Y);for(let t of i){let o=s.directives[t]||[];for(let n of o)if(g(n)==="*"){e.push(new c(304,t+" should not allow '*' as source",10,t,n));continue}}return e}function Re(s){let e=[];return"object-src"in s.directives?e=s.directives["object-src"]:"default-src"in s.directives&&(e=s.directives["default-src"]),e!==void 0&&e.length>=1?[]:[new c(300,"Missing object-src allows the injection of plugins which can execute JavaScript. Can you set it to 'none'?",10,"object-src")]}function Ce(s){return"script-src"in s.directives||"default-src"in s.directives?[]:[new c(300,"script-src directive is missing.",10,"script-src")]}function Ie(s){return we([s])}function we(s){let e=t=>t.policyHasScriptNonces()||t.policyHasScriptHashes()&&t.policyHasStrictDynamic(),i=t=>"base-uri"in t.directives;if(s.some(e)&&!s.some(i)){let t="Missing base-uri allows the injection of base tags. They can be used to set the base URL for all relative (script) URLs to an attacker controlled domain. Can you set it to 'none' or 'self'?";return[new c(300,t,10,"base-uri")]}return[]}function K(s){return[...Re(s),...Ce(s),...Ie(s)]}function q(s){let e=[],i=s.getEffectiveDirective("script-src"),t=s.directives[i]||[];if(t.includes("'none'"))return e;for(let o of t){if(o==="'self'"){e.push(new c(305,"'self' can be problematic if you host JSONP, AngularJS or user uploaded files.",50,i,o));continue}if(o.startsWith("'")||C(o)||o.indexOf(".")===-1)continue;let n="//"+g(o),l=I(n,x),a=I(n,U);if(a){let u=j.includes(a.hostname),p=t.includes("'unsafe-eval'");u&&!p&&(a=null)}if(a||l){let u="",p="";a&&(u=a.hostname,p=" JSONP endpoints"),l&&(u=l.hostname,p+=p.trim()===""?"":" and",p+=" Angular libraries"),e.push(new c(305,u+" is known to host"+p+" which allow to bypass this CSP.",10,i,o))}else e.push(new c(305,"No bypass found; make sure that this URL doesn't serve JSONP replies or Angular libraries.",50,i,o))}return e}function z(s){let e=[],i=s.getEffectiveDirective("object-src"),t=s.directives[i]||[],o=s.directives["plugin-types"];if(o&&!o.includes("application/x-shockwave-flash"))return[];for(let n of t){if(n==="'none'")return[];let l="//"+g(n),a=I(l,y);a?e.push(new c(306,a.hostname+" is known to host Flash files which allow to bypass this CSP.",10,i,n)):i==="object-src"&&e.push(new c(306,"Can you restrict object-src to 'none' only?",50,i,n))}return e}function Te(s){return!!(s.startsWith("[")&&s.endsWith("]")||/^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/.test(s))}function J(s){let e=[];return w(s,(t,o)=>{for(let n of o){let l=M(n);Te(l)&&(l==="127.0.0.1"?e.push(new c(308,t+" directive allows localhost as source. Please make sure to remove this in production environments.",60,t,n)):e.push(new c(308,t+" directive has an IP-Address as source: "+l+" (will be ignored by browsers!). ",60,t,n)))}}),e}function X(s){let e=[];return"reflected-xss"in s.directives&&e.push(new c(309,"reflected-xss is deprecated since CSP2. Please, use the X-XSS-Protection header instead.",60,"reflected-xss")),"referrer"in s.directives&&e.push(new c(309,"referrer is deprecated since CSP2. Please, use the Referrer-Policy header instead.",60,"referrer")),"disown-opener"in s.directives&&e.push(new c(309,"disown-opener is deprecated since CSP3. Please, use the Cross Origin Opener Policy header instead.",60,"disown-opener")),e}function Q(s){let e=new RegExp("^'nonce-(.+)'$"),i=[];return w(s,(t,o)=>{for(let n of o){let l=n.match(e);if(!l)continue;l[1].length<8&&i.push(new c(307,"Nonces should be at least 8 characters long.",30,t,n)),E(n,!0)||i.push(new c(106,"Nonces should only use the base64 charset.",60,t,n))}}),i}function $(s){let e=[];return w(s,(i,t)=>{for(let o of t){let n=i==="report-uri"?"Use HTTPS to send violation reports securely.":"Allow only resources downloaded over HTTPS.";o.startsWith("http://")&&e.push(new c(310,n,30,i,o))}}),e}function Z(s){let e=s.getEffectiveDirective("script-src"),i=s.directives[e]||[];return i.some(o=>!o.startsWith("'"))&&!i.includes("'strict-dynamic'")?[new c(400,"Host allowlists can frequently be bypassed. Consider using 'strict-dynamic' in combination with CSP nonces or hashes.",45,e)]:[]}function ee(s){let e=s.getEffectiveDirective("script-src");return(s.directives[e]||[]).includes("'strict-dynamic'")&&!s.policyHasScriptNonces()&&!s.policyHasScriptHashes()?[new c(401,"'strict-dynamic' without a CSP nonce/hash will block all scripts.",60,e)]:[]}function se(s){if(!s.policyHasScriptNonces()&&!s.policyHasScriptHashes())return[];let e=s.getEffectiveDirective("script-src");return(s.directives[e]||[]).includes("'unsafe-inline'")?[]:[new c(403,"Consider adding 'unsafe-inline' (ignored by browsers supporting nonces/hashes) to be backward compatible with older browsers.",45,e)]}function ie(s){let e=s.getEffectiveDirective("script-src"),i=s.directives[e]||[];return i.includes("'strict-dynamic'")?i.some(t=>["http:","https:","*"].includes(t)||t.includes("."))?[]:[new c(404,"Consider adding https: and http: url schemes (ignored by browsers supporting 'strict-dynamic') to be backward compatible with older browsers.",45,e)]:[]}function te(s){let e=s.getEffectiveDirective("require-trusted-types-for");return(s.directives[e]||[]).includes("'script'")?[]:[new c(500,`Consider requiring Trusted Types for scripts to lock down DOM XSS injection sinks. You can do this by adding "require-trusted-types-for 'script'" to your policy.`,60,"require-trusted-types-for")]}var k=class{version;csp;findings=[];constructor(e,i){this.version=i||3,this.csp=e}evaluate(e,i){this.findings=[];let t=i||ne,o=this.csp.getEffectiveCsp(this.version,this.findings);if(e)for(let n of e)this.findings=this.findings.concat(n(this.csp));for(let n of t)this.findings=this.findings.concat(n(o));return this.findings}},ne=[W,B,V,G,K,q,z,J,Q,$,X,P,F,L],ke=[Z,ee,se,ie,te];var re={};O(re,{CspParser:()=>A,TEST_ONLY:()=>Ae});var A=class{csp;constructor(e){this.csp=new f,this.parse(e)}parse(e){this.csp=new f;let i=e.split(";");for(let t=0;t<i.length;t++){let n=i[t].trim().match(/\S+/g);if(Array.isArray(n)){let l=n[0].toLowerCase();if(l in this.csp.directives)continue;S(l);let a=[];for(let u,p=1;u=n[p];p++)u=ce(u),a.includes(u)||a.push(u);this.csp.directives[l]=a}}return this.csp}};function ce(s){s=s.trim();let e=s.toLowerCase();return R(e)||C(s)?e:s}var Ae={normalizeDirectiveValue:ce};export{oe as CspEvaluator,re as CspParser};
/**
 * @license
 * Copyright 2016 Google Inc. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * @author lwe@google.com (Lukas Weichselbaum)
 */
/**
 * @fileoverview CSP definitions and helper functions.
 * @author lwe@google.com (Lukas Weichselbaum)
 *
 * @license
 * Copyright 2016 Google Inc. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * @fileoverview Collection of CSP parser checks which can be used to find
 * common syntax mistakes like missing semicolons, invalid directives or
 * invalid keywords.
 * @author lwe@google.com (Lukas Weichselbaum)
 *
 * @license
 * Copyright 2016 Google Inc. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * @fileoverview Collection of popular sites/CDNs hosting Angular.
 * @author lwe@google.com (Lukas Weichselbaum)
 *
 * @license
 * Copyright 2016 Google Inc. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * @fileoverview Collection of popular sites/CDNs hosting flash with user
 * provided JS.
 * @author lwe@google.com (Lukas Weichselbaum)
 *
 * @license
 * Copyright 2016 Google Inc. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * @fileoverview Collection of popular sites/CDNs hosting JSONP-like endpoints.
 * Endpoints don't contain necessary parameters to trigger JSONP response
 * because parameters are ignored in CSP allowlists.
 * Usually per domain only one (popular) file path is listed to allow bypasses
 * of the most common path based allowlists. It's not practical to ship a list
 * for all possible paths/domains. Therefore the jsonp bypass check usually only
 * works efficient for domain based allowlists.
 * @author lwe@google.com (Lukas Weichselbaum)
 *
 * @license
 * Copyright 2016 Google Inc. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * @fileoverview Utils for CSP evaluator.
 * @author lwe@google.com (Lukas Weichselbaum)
 *
 * @license
 * Copyright 2016 Google Inc. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * @fileoverview Collection of CSP evaluation checks.
 * @author lwe@google.com (Lukas Weichselbaum)
 *
 * @license
 * Copyright 2016 Google Inc. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * @fileoverview Collection of "strict" CSP and backward compatibility checks.
 * A "strict" CSP is based on nonces or hashes and drops the allowlist.
 * These checks ensure that 'strict-dynamic' and a CSP nonce/hash are present.
 * Due to 'strict-dynamic' any allowlist will get dropped in CSP3.
 * The backward compatibility checks ensure that the strict nonce/hash based CSP
 * will be a no-op in older browsers by checking for presence of 'unsafe-inline'
 * (will be dropped in newer browsers if a nonce or hash is present) and for
 * prsensence of http: and https: url schemes (will be droped in the presence of
 * 'strict-dynamic' in newer browsers).
 *
 * @author lwe@google.com (Lukas Weichselbaum)
 *
 * @license
 * Copyright 2016 Google Inc. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * @author lwe@google.com (Lukas Weichselbaum)
 *
 * @license
 * Copyright 2016 Google Inc. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
//# sourceMappingURL=csp_evaluator.js.map
