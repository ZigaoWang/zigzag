var v=Object.defineProperty;var f=(e,t)=>{for(var i in t)v(e,i,{get:t[i],enumerable:!0})};var g={};f(g,{DEFAULT_AUTO_DISMISS_MS:()=>h,Snackbar:()=>a});import*as u from"../../../core/i18n/i18n.js";import*as r from"../../visual_logging/visual_logging.js";import*as m from"../../legacy/legacy.js";import*as s from"../../lit/lit.js";import*as l from"../buttons/buttons.js";var b=`:host{position:fixed;bottom:var(--sys-size-5);left:var(--sys-size-5);z-index:9999;max-width:calc(100% - 2 * var(--sys-size-5));.container{display:flex;align-items:center;overflow:hidden;width:var(--sys-size-31);padding:var(--sys-size-6);background:var(--sys-color-inverse-surface);box-shadow:var(--sys-elevation-level3);border-radius:var(--sys-shape-corner-small);font:var(--sys-typescale-body4-medium);animation:slideIn 100ms cubic-bezier(0,0,0.3,1);box-sizing:border-box;max-width:100%;&.closable{padding:var(--sys-size-5) var(--sys-size-5) var(--sys-size-5) var(--sys-size-6);&.long-action{padding:var(--sys-size-5) var(--sys-size-6) var(--sys-size-6) var(--sys-size-6)}}&.long-action{flex-direction:column;align-items:flex-start;.long-action-container{margin-left:auto}}.label-container{display:flex;width:100%;align-items:center;gap:var(--sys-size-5);.message{width:100%;color:var(--sys-color-inverse-on-surface);flex:1 0 0;text-wrap:pretty;user-select:text}}devtools-button.dismiss{padding:3px}}}@keyframes slideIn{from{transform:translateY(var(--sys-size-5));opacity:0%}to{opacity:100%}}
/*# sourceURL=${import.meta.resolve("./snackbar.css")} */`;var{html:o}=s,c={dismiss:"Dismiss"},k=u.i18n.registerUIStrings("ui/components/snackbars/Snackbar.ts",c),d=u.i18n.getLocalizedString.bind(void 0,k),h=5e3,p=15,a=class e extends HTMLElement{#a=this.attachShadow({mode:"open"});#n;#t=null;#s=!1;#i;static snackbarQueue=[];get dismissTimeout(){return this.hasAttribute("dismiss-timeout")?Number(this.getAttribute("dismiss-timeout")):h}set dismissTimeout(t){this.setAttribute("dismiss-timeout",t.toString())}get message(){return this.getAttribute("message")}set message(t){this.setAttribute("message",t)}get closable(){return this.hasAttribute("closable")}set closable(t){this.toggleAttribute("closable",t)}get actionButtonLabel(){return this.getAttribute("action-button-label")}set actionButtonLabel(t){this.setAttribute("action-button-label",t)}get actionButtonTitle(){return this.getAttribute("action-button-title")}set actionButtonTitle(t){this.setAttribute("action-button-title",t)}set actionButtonClickHandler(t){this.#i=t}constructor(t,i){super(),this.message=t.message,this.#n=i||m.InspectorView.InspectorView.instance().element,t.closable&&(this.closable=t.closable),t.actionProperties&&(this.actionButtonLabel=t.actionProperties.label,this.#i=t.actionProperties.onClick,t.actionProperties.title&&(this.actionButtonTitle=t.actionProperties.title))}static show(t,i){let n=new e(t,i);return e.snackbarQueue.push(n),e.snackbarQueue.length===1&&n.#o(),n}#o(){this.#n.appendChild(this),this.#t&&window.clearTimeout(this.#t),this.closable||(this.#t=window.setTimeout(()=>{this.#e()},this.dismissTimeout))}#e(){if(this.#t&&window.clearTimeout(this.#t),this.remove(),e.snackbarQueue.shift(),e.snackbarQueue.length>0){let t=e.snackbarQueue[0];t&&t.#o()}}#r(t){this.#i&&(t.preventDefault(),this.#i(),this.#e())}connectedCallback(){this.actionButtonLabel&&(this.#s=this.actionButtonLabel.length>p),this.role="alert";let t=s.Directives.classMap({container:!0,"long-action":!!this.#s,closable:!!this.closable}),i=this.actionButtonLabel?o`<devtools-button
        class="snackbar-button"
        @click=${this.#r}
        jslog=${r.action("snackbar.action").track({click:!0})}
        .variant=${l.Button.Variant.TEXT}
        .title=${this.actionButtonTitle??""}
        .inverseColorTheme=${!0}
    >${this.actionButtonLabel}</devtools-button>`:s.nothing,n=this.closable?o`<devtools-button
        class="dismiss snackbar-button"
        @click=${this.#e}
        jslog=${r.action("snackbar.dismiss").track({click:!0})}
        aria-label=${d(c.dismiss)}
        .iconName=${"cross"}
        .variant=${l.Button.Variant.ICON}
        .title=${d(c.dismiss)}
        .inverseColorTheme=${!0}
    ></devtools-button>`:s.nothing;s.render(o`
        <style>${b}</style>
        <div class=${t}>
            <div class="label-container">
                <div class="message">${this.message}</div>
                ${this.#s?s.nothing:i}
                ${n}
            </div>
            ${this.#s?o`<div class="long-action-container">${i}</div>`:s.nothing}
        </div>
    `,this.#a,{host:this})}};customElements.define("devtools-snackbar",a);export{g as Snackbar};
//# sourceMappingURL=snackbars.js.map
