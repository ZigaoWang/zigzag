var G=Object.defineProperty;var m=(o,t)=>{for(var e in t)G(o,e,{get:t[e],enumerable:!0})};var I={};m(I,{VideoType:()=>g,getReleaseNote:()=>n,setReleaseNoteForTest:()=>q});import*as T from"../../ui/components/markdown_view/markdown_view.js";var x=!1,g=(r=>(r.WHATS_NEW="WhatsNew",r.DEVTOOLS_TIPS="DevtoolsTips",r.OTHER="Other",r))(g||{});function q(o){p=o}function n(){if(!x){for(let{key:o,link:t}of p.markdownLinks)T.MarkdownLinksMap.markdownLinks.set(o,t);x=!0}return p}var p={version:158,header:"New in DevTools (December 2026)",markdownLinks:[{key:"mcp",link:"https://developer.chrome.com/blog/new-in-devtools-december-2026/#mcp"},{key:"sources",link:"https://developer.chrome.com/blog/new-in-devtools-december-2026/#sources"},{key:"performance",link:"https://developer.chrome.com/blog/new-in-devtools-december-2026/#performance"}],videoLinks:[],link:"https://developer.chrome.com/blog/new-in-devtools-december-2026/"};var E={};m(E,{DEVTOOLS_TIPS_THUMBNAIL:()=>D,GENERAL_THUMBNAIL:()=>C,ReleaseNoteView:()=>l,WHATS_NEW_THUMBNAIL:()=>A,getMarkdownContent:()=>H});import"../../ui/components/markdown_view/markdown_view.js";import"../../ui/kit/kit.js";import*as u from"../../core/i18n/i18n.js";import*as P from"../../third_party/marked/marked.js";import*as U from"../../ui/components/buttons/buttons.js";import*as V from"../../ui/helpers/helpers.js";import*as M from"../../ui/legacy/legacy.js";import{html as v,render as X}from"../../ui/lit/lit.js";import*as z from"../../ui/visual_logging/visual_logging.js";var R=`@scope to (devtools-widget > *){.whatsnew{background:var(--sys-color-header-container);flex-grow:1;flex-shrink:0;display:flex;width:100%;height:100%;overflow:auto;justify-content:center}.whatsnew-content{max-width:var(--sys-size-35);padding:var(--sys-size-9) 0 0;>*{padding:0 var(--sys-size-9) var(--sys-size-9) var(--sys-size-9)}}.header{display:flex;align-items:center;font:var(--sys-typescale-headline4);&::before{content:"";width:var(--sys-size-9);height:var(--sys-size-9);transform:scale(1.6);margin:0 var(--sys-size-8) 0 var(--sys-size-4);background-image:var(--image-file-devtools);flex-shrink:0}}.feature-container{flex-grow:1;padding:0;background-color:var(--sys-color-surface);border-radius:var(--sys-shape-corner-large) var(--sys-shape-corner-large) 0 0;display:flex;flex-direction:column}.feature{background-color:var(--sys-color-surface3);padding:0 var(--sys-size-8) var(--sys-size-8);border-radius:var(--sys-shape-corner-medium);margin:0 var(--sys-size-9) var(--sys-size-9)}.video-container{margin-bottom:var(--sys-size-9);&:has(.video){--video-bottom-padding:var(--sys-size-6);overflow:auto;display:flex;flex-direction:row;gap:var(--sys-size-5);padding:var(--sys-size-9) var(--sys-size-9) var(--video-bottom-padding);margin-bottom:calc(var(--sys-size-9) - var(--video-bottom-padding));> *{min-width:auto}}}.video{align-items:center;display:flex;flex-direction:row;border-radius:var(--sys-shape-corner-medium);background-color:var(--sys-color-surface3);font:var(--sys-typescale-body5-regular);min-width:var(--sys-size-29);max-width:var(--sys-size-32);overflow:hidden;height:72px;&:hover{box-shadow:var(--sys-elevation-level3)}.thumbnail{border-radius:var(--sys-shape-corner-medium) 0 0 var(--sys-shape-corner-medium);flex-shrink:0}.thumbnail-description{--description-margin:var(--sys-size-6);margin:var(--description-margin);height:calc(100% - var(--description-margin) * 2);overflow:hidden}}devtools-link:focus .video{outline:var(--sys-size-2) solid var(--sys-color-state-focus-ring)}@media (forced-colors: active){.feature,
    .video{border:var(--sys-size-1) solid ButtonText}}}
/*# sourceURL=${import.meta.resolve("./releaseNoteView.css")} */`;var L={seeFeatures:"See all new features"},Y=u.i18n.registerUIStrings("panels/whats_new/ReleaseNoteView.ts",L),J=u.i18n.getLocalizedString.bind(void 0,Y),A="../../Images/whatsnew.svg",D="../../Images/devtools-tips.svg",C="../../Images/devtools-thumbnail.svg";async function H(){let o=await l.getFileContent(),t=P.Marked.lexer(o),e=[],r=Number.MAX_SAFE_INTEGER;return t.forEach(s=>{s.type==="heading"&&r>=s.depth?(e.push([s]),r=s.depth):e.length>0?e[e.length-1].push(s):e.push([s])}),e}var l=class extends M.Panel.Panel{#e;constructor(t=(e,r,s)=>{let d=e.getReleaseNote(),j=e.markdownContent;X(v`
      <style>${R}</style>
      <div class="whatsnew" jslog=${z.section().context("release-notes")}>
        <div class="whatsnew-content">
          <div class="header">
            ${d.header}
          </div>
          <div>
            <devtools-button
                  .variant=${U.Button.Variant.PRIMARY}
                  .jslogContext=${"learn-more"}
                  @click=${()=>e.openNewTab(d.link)}
              >${J(L.seeFeatures)}</devtools-button>
          </div>

          <div class="feature-container">
            <div class="video-container">
              ${d.videoLinks.map(i=>v`
                  <devtools-link
                  href=${i.link}
                  jslogcontext="learn-more">
                    <div class="video">
                      <img class="thumbnail" src=${e.getThumbnailPath(i.type??"WhatsNew")}>
                      <div class="thumbnail-description"><span>${i.description}</span></div>
                    </div>
                </devtools-link>
                `)}
            </div>
            ${j.map(i=>v`
                  <div class="feature">
                    <devtools-markdown-view slot="content" .data=${{tokens:i}}>
                    </devtools-markdown-view>
                  </div>`)}
          </div>
        </div>
      </div>
    `,s)}){super("whats-new",!0),this.#e=t,this.requestUpdate()}static async getFileContent(){let t=new URL("./resources/WNDT.md",import.meta.url);try{return await(await fetch(t.toString())).text()}catch{throw new Error(`Markdown file ${t.toString()} not found. Make sure it is correctly listed in the relevant BUILD.gn files.`)}}async performUpdate(){let t=await H();this.#e({getReleaseNote:n,openNewTab:V.openInNewTab,markdownContent:t,getThumbnailPath:this.#t},this,this.contentElement)}#t(t){let e;switch(t){case"WhatsNew":e=A;break;case"DevtoolsTips":e=D;break;case"Other":e=C;break}return new URL(e,import.meta.url).toString()}};var F={};m(F,{HelpLateInitialization:()=>y,ReleaseNotesActionDelegate:()=>b,ReportIssueActionDelegate:()=>N,getReleaseNoteVersionSetting:()=>K,releaseNoteViewId:()=>O,releaseVersionSeen:()=>c,showReleaseNoteIfNeeded:()=>B});import*as a from"../../core/common/common.js";import*as _ from"../../core/host/host.js";import*as S from"../../ui/helpers/helpers.js";import*as $ from"../../ui/legacy/legacy.js";import*as W from"../../ui/settings/settings.js";var c="releaseNoteVersionSeen",O="release-note",f;function B(){let t=a.Settings.Settings.instance().createSetting(c,0).get(),e=n();return Q(t,e.version,a.Settings.Settings.instance().resolve(W.WhatsNewSettings.showReleaseNoteSettingDescriptor).get())}function K(){return f||(f=a.Settings.Settings.instance().createSetting(c,0)),f}function Q(o,t,e){let r=a.Settings.Settings.instance().createSetting(c,0);return o?!e||o>=t?!1:(r.set(t),$.ViewManager.ViewManager.instance().showView(O,!0),!0):(r.set(t),!1)}var w,y=class o{static instance(t={forceNew:null}){let{forceNew:e}=t;return(!w||e)&&(w=new o),w}async run(){_.InspectorFrontendHost.isUnderTest()||B()}},h,b=class o{handleAction(t,e){let r=n();return S.openInNewTab(r.link),!0}static instance(t={forceNew:null}){let{forceNew:e}=t;return(!h||e)&&(h=new o),h}},k,N=class o{handleAction(t,e){return S.openInNewTab("https://goo.gle/devtools-bug"),!0}static instance(t={forceNew:null}){let{forceNew:e}=t;return(!k||e)&&(k=new o),k}};export{I as ReleaseNoteText,E as ReleaseNoteView,F as WhatsNew};
//# sourceMappingURL=whats_new.js.map
