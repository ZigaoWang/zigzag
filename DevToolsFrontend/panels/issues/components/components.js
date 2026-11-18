var E=Object.defineProperty;var a=(s,e)=>{for(var t in e)E(s,t,{get:e[t],enumerable:!0})};var d={};a(d,{ElementsPanelLink:()=>n});import{html as I,render as f}from"../../../ui/lit/lit.js";import*as m from"../../../ui/visual_logging/visual_logging.js";var r=`.element-reveal-icon{display:inline-block;width:var(--sys-size-9);height:var(--sys-size-9);mask-image:var(--image-file-select-element);background-color:var(--icon-default)}
/*# sourceURL=${import.meta.resolve("././elementsPanelLink.css")} */`;var n=class extends HTMLElement{#n=this.attachShadow({mode:"open"});#e=()=>{};#t=()=>{};#o=()=>{};set data(e){this.#e=e.onElementRevealIconClick,this.#t=e.onElementRevealIconMouseEnter,this.#o=e.onElementRevealIconMouseLeave,this.#s()}#s(){this.#i()}#i(){f(I`
      <style>${r}</style>
      <span
        class="element-reveal-icon"
        jslog=${m.link("elements-panel").track({click:!0})}
        @click=${this.#e}
        @mouseenter=${this.#t}
        @mouseleave=${this.#o}></span>
      `,this.#n,{host:this})}};customElements.define("devtools-elements-panel-link",n);var g={};a(g,{HideIssuesMenu:()=>o});import*as u from"../../../core/common/common.js";import*as i from"../../../core/i18n/i18n.js";import*as v from"../../../ui/components/buttons/buttons.js";import*as p from"../../../ui/legacy/legacy.js";import{html as y,render as L}from"../../../ui/lit/lit.js";var c=`.hide-issues-menu-btn{position:relative;display:flex;background-color:transparent;flex:none;align-items:center;justify-content:center;padding:0;margin:0 calc(-1 * var(--sys-size-2)) 0 var(--sys-size-3);overflow:hidden;border-radius:0;border:none;&:hover > devtools-icon{color:var(--icon-default-hover)}}
/*# sourceURL=${import.meta.resolve("././hideIssuesMenu.css")} */`;var h={tooltipTitle:"Hide issues"},M=i.i18n.registerUIStrings("panels/issues/components/HideIssuesMenu.ts",h),k=i.i18n.getLocalizedString.bind(void 0,M),o=class extends HTMLElement{#n=this.attachShadow({mode:"open"});#e=u.UIString.LocalizedEmptyString;#t=()=>{};set data(e){this.#e=e.menuItemLabel,this.#t=e.menuItemAction,this.#o()}onMenuOpen(e){e.stopPropagation();let t=this.#n.querySelector("devtools-button"),l=new p.ContextMenu.ContextMenu(e,{x:t?.getBoundingClientRect().left,y:t?.getBoundingClientRect().bottom});l.headerSection().appendItem(this.#e,()=>this.#t(),{jslogContext:"toggle-similar-issues"}),l.show()}onKeydown(e){(e.key==="Enter"||e.key==="Space")&&e.stopImmediatePropagation()}#o(){L(y`
    <style>${c}</style>
    <devtools-button
      .data=${{variant:v.Button.Variant.ICON,iconName:"dots-vertical",title:k(h.tooltipTitle)}}
      .jslogContext=${"hide-issues"}
      class="hide-issues-menu-btn"
      @click=${this.onMenuOpen}
      @keydown=${this.onKeydown}></devtools-button>
    `,this.#n,{host:this})}};customElements.define("devtools-hide-issues-menu",o);export{d as ElementsPanelLink,g as HideIssuesMenu};
//# sourceMappingURL=components.js.map
