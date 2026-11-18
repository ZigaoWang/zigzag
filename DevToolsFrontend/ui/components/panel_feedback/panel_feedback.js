var P=Object.defineProperty;var c=(i,e)=>{for(var t in e)P(i,t,{get:e[t],enumerable:!0})};var T={};c(T,{FeedbackButton:()=>s});import*as y from"../../../core/host/host.js";import*as p from"../../../core/i18n/i18n.js";import*as x from"../../../core/platform/platform.js";import*as m from"../helpers/helpers.js";import{html as R,render as E}from"../../lit/lit.js";import*as w from"../buttons/buttons.js";var S={feedback:"Feedback"},z=p.i18n.registerUIStrings("ui/components/panel_feedback/FeedbackButton.ts",S),C=p.i18n.getLocalizedString.bind(void 0,z),s=class extends HTMLElement{#i=this.attachShadow({mode:"open"});#e={feedbackUrl:x.DevToolsPath.EmptyUrlString};set data(e){this.#e=e,m.ScheduledRender.scheduleRender(this,this.#o)}#t(){y.InspectorFrontendHost.InspectorFrontendHostInstance.openInNewTab(this.#e.feedbackUrl)}#o(){if(!m.ScheduledRender.isScheduledRender(this))throw new Error("FeedbackButton render was not scheduled");E(R`
      <devtools-button
          @click=${this.#t}
          .iconName=${"review"}
          .variant=${w.Button.Variant.OUTLINED}
          .jslogContext=${"feedback"}
      >${C(S.feedback)}</devtools-button>
      `,this.#i,{host:this})}};customElements.define("devtools-feedback-button",s);var L={};c(L,{PanelFeedback:()=>r});import"../../kit/kit.js";import*as k from"../../../core/i18n/i18n.js";import*as h from"../../../core/platform/platform.js";import*as v from"../helpers/helpers.js";import{html as D,render as H}from"../../lit/lit.js";var $=`:host{display:block}.preview{padding:var(--sys-size-6) var(--sys-size-8);border:var(--sys-size-1) solid var(--sys-color-divider);color:var(--sys-color-on-surface);font-size:var(--sys-typescale-body3-size);line-height:var(--sys-typescale-body3-line-height);border-radius:var(--sys-shape-corner-medium-small);margin:42px 0;letter-spacing:0.01em}h2{color:var(--sys-color-primary);font-size:var(--sys-typescale-body3-size);line-height:var(--sys-typescale-body3-line-height);letter-spacing:0.01em;margin:9px 0 var(--sys-size-7);display:flex;align-items:center;gap:5px;font-weight:normal}h3{font-size:var(--sys-typescale-body3-size);line-height:var(--sys-typescale-body3-line-height);letter-spacing:0.04em;color:var(--sys-color-on-surface);margin-bottom:var(--sys-size-2);font-weight:normal}.preview p{margin-bottom:var(--sys-size-11)}.thumbnail{height:92px}.video{display:flex;flex-flow:row wrap;gap:var(--sys-size-9)}devtools-link{color:var(--sys-color-primary);text-decoration-line:underline}devtools-link.quick-start-link{font-size:var(--sys-typescale-body2-size);line-height:var(--sys-size-10);letter-spacing:0.04em}.video-description{min-width:min-content;flex-basis:min-content;flex-grow:1}@media (forced-colors: active){devtools-link{color:linktext}}
/*# sourceURL=${import.meta.resolve("./panelFeedback.css")} */`;var o={previewText:"Our team is actively working on this feature and we would love to know what you think",previewTextFeedbackLink:"Send us your feedback",previewFeature:"Preview feature",videoAndDocumentation:"Video and documentation"},M=k.i18n.registerUIStrings("ui/components/panel_feedback/PanelFeedback.ts",o),n=k.i18n.getLocalizedString.bind(void 0,M),I=new URL("../../../Images/preview_feature_video_thumbnail.svg",import.meta.url).toString(),r=class extends HTMLElement{#i=this.attachShadow({mode:"open"});#e={feedbackUrl:h.DevToolsPath.EmptyUrlString,quickStartUrl:h.DevToolsPath.EmptyUrlString,quickStartLinkText:""};set data(e){this.#e=e,v.ScheduledRender.scheduleRender(this,this.#t)}#t(){if(!v.ScheduledRender.isScheduledRender(this))throw new Error("PanelFeedback render was not scheduled");H(D`
      <style>${$}</style>
      <div class="preview">
        <h2 class="flex">
          <devtools-icon name="experiment" class="extra-large" style="color: var(--icon-primary);"></devtools-icon> ${n(o.previewFeature)}
        </h2>
        <p>${n(o.previewText)} <devtools-link href=${this.#e.feedbackUrl} .jslogContext=${"feedback"}>${n(o.previewTextFeedbackLink)}</devtools-link></p>
        <div class="video">
          <div class="thumbnail">
            <img src=${I} role="presentation" />
          </div>
          <div class="video-description">
            <h3>${n(o.videoAndDocumentation)}</h3>
            <devtools-link class="quick-start-link" href=${this.#e.quickStartUrl} jslogcontext="css-overview.quick-start">${this.#e.quickStartLinkText}</devtools-link>
          </div>
        </div>
      </div>
      `,this.#i,{host:this})}};customElements.define("devtools-panel-feedback",r);var F={};c(F,{PreviewToggle:()=>d});import"../../kit/kit.js";import"../../legacy/legacy.js";import*as u from"../../../core/i18n/i18n.js";import*as b from"../../../core/root/root.js";import{html as a,nothing as f,render as B}from"../../lit/lit.js";var U=`:host{display:block}.container{display:flex;flex-wrap:wrap;padding:var(--sys-size-3)}.feedback,
.learn-more{display:flex;align-items:center}.helper{flex-basis:100%;text-align:center;font-style:italic}.spacer{flex:1}.devtools-link{color:var(--sys-color-primary);text-decoration-line:underline;margin:0 var(--sys-size-3)}.feedback .devtools-link{color:var(--sys-color-token-subtle)}
/*# sourceURL=${import.meta.resolve("./previewToggle.css")} */`;var l={previewTextFeedbackLink:"Send us your feedback",shortFeedbackLink:"Send feedback",learnMoreLink:"Learn more"},N=u.i18n.registerUIStrings("ui/components/panel_feedback/PreviewToggle.ts",l),g=u.i18n.getLocalizedString.bind(void 0,N),d=class extends HTMLElement{#i=this.attachShadow({mode:"open"});#e="";#t=null;#o=null;#n;#s="";#r;set data(e){this.#e=e.name,this.#t=e.helperText,this.#o=e.feedbackURL,this.#n=e.learnMoreURL,this.#s=e.experiment,this.#r=e.onChangeCallback,this.#a()}#a(){let e=this.#s&&b.Runtime.experiments.isEnabled(this.#s);B(a`
      <style>${U}</style>
      <div class="container">
          <devtools-checkbox
            .checked=${!!e}
            @change=${this.#l}
            aria-label=${this.#e} >
            <devtools-icon name="experiment" class="medium">
          </devtools-icon>${this.#e}
          </devtools-checkbox>
        <div class="spacer"></div>
        ${this.#o&&!this.#t?a`<div class="feedback"><devtools-link class="devtools-link" href=${this.#o} jslogContext=${"feedback"}>${g(l.shortFeedbackLink)}</devtools-link></div>`:f}
        ${this.#n?a`<div class="learn-more"><devtools-link class="devtools-link" href=${this.#n} jslogContext=${"learn-more"}>${g(l.learnMoreLink)}</devtools-link></div>`:f}
        <div class="helper">
          ${this.#t&&this.#o?a`<p>${this.#t} <devtools-link class="devtools-link" href=${this.#o} jslogContext=${"feedback"}>${g(l.previewTextFeedbackLink)}</devtools-link></p>`:f}
        </div>
      </div>`,this.#i,{host:this})}#l(e){let t=e.target.checked;this.#s&&b.Runtime.experiments.setEnabled(this.#s,t),this.#r?.(t)}};customElements.define("devtools-preview-toggle",d);export{T as FeedbackButton,L as PanelFeedback,F as PreviewToggle};
//# sourceMappingURL=panel_feedback.js.map
