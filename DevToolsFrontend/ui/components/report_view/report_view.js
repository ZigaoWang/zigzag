var b=Object.defineProperty;var S=(t,o)=>{for(var r in o)b(t,r,{get:o[r],enumerable:!0})};var w={};S(w,{Report:()=>i,ReportKey:()=>d,ReportSection:()=>a,ReportSectionDivider:()=>n,ReportSectionHeader:()=>l,ReportValue:()=>c});import*as v from"../../../core/platform/platform.js";import*as x from"../../legacy/components/utils/utils.js";import{html as e,nothing as p,render as s}from"../../lit/lit.js";var h=`:host{display:block}.content{background-color:var(--sys-color-cdt-base-container);display:grid;grid-template-columns:min-content 1fr;user-select:text;margin:var(--sys-size-5) 0}.report-header-wrapper{border-bottom:var(--sys-size-1) solid var(--sys-color-divider)}.report-title{padding:var(--sys-size-7) var(--sys-size-9);font:var(--sys-typescale-headline4);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--sys-color-on-surface);background-color:var(--sys-color-cdt-base-container);margin:0}.report-url{background:none;border-radius:var(--sys-size-2);border:none;color:var(--text-link);cursor:pointer;display:block;font:var(--sys-typescale-body4-regular);height:unset;margin:0;outline-offset:var(--sys-size-2);outline:none;padding:0!important;text-decoration:underline}
/*# sourceURL=${import.meta.resolve("./report.css")} */`;var m=`:host{margin:var(--sys-size-3) 0 var(--sys-size-3) var(--sys-size-9);min-width:150px}.key{color:var(--sys-color-on-surface-subtle);font:var(--sys-typescale-body5-medium);padding-right:var(--sys-size-6);text-align:left;white-space:pre;user-select:none;line-height:18px}
/*# sourceURL=${import.meta.resolve("./reportKey.css")} */`;var y=`:host{grid-column-start:span 2;min-width:min-content}.section{padding:var(--sys-size-5) var(--sys-size-9);display:flex;flex-direction:row;align-items:center;flex:auto;overflow-wrap:break-word;overflow:hidden}
/*# sourceURL=${import.meta.resolve("./reportSection.css")} */`;var f=`:host{grid-column-start:span 2}:host(.subsection-divider){padding-left:var(--sys-size-9)}.section-divider{margin:var(--sys-size-5) 0;border-bottom:var(--sys-size-1) solid var(--sys-color-divider)}
/*# sourceURL=${import.meta.resolve("./reportSectionDivider.css")} */`;var u=`:host{grid-column-start:span 2}.section-header{font:var(--sys-typescale-headline5);margin:var(--sys-size-4) 0 var(--sys-size-5) var(--sys-size-9);display:flex;flex-direction:row;align-items:center;flex:auto;text-overflow:ellipsis;overflow:hidden;color:var(--sys-color-on-surface);user-select:none}
/*# sourceURL=${import.meta.resolve("./reportSectionHeader.css")} */`;var g=`:host{margin:var(--sys-size-3) var(--sys-size-9) var(--sys-size-3) var(--sys-size-9);min-width:150px}.value{font:var(--sys-typescale-body4-regular);color:var(--sys-color-on-surface);margin-inline-start:0;padding:0 var(--sys-size-4);overflow-wrap:break-word;line-height:18px}
/*# sourceURL=${import.meta.resolve("./reportValue.css")} */`;var i=class extends HTMLElement{#t=this.attachShadow({mode:"open"});#e="";#o=v.DevToolsPath.EmptyUrlString;set data({reportTitle:o,reportUrl:r}){this.#e=o,this.#o=r??v.DevToolsPath.EmptyUrlString,this.#s()}connectedCallback(){this.#s()}#s(){let o=this.querySelector('[slot="toolbar"]')!==null;s(e`
      <style>${h}</style>
      ${this.#e||o?e`
        <div class="report-header-wrapper">
          ${this.#e?e`<h1 class="report-title">
            ${this.#e}
            ${this.#o?x.Linkifier.Linkifier.linkifyURL(this.#o,{tabStop:!0,jslogContext:"source-location",className:"report-url"}):p}
          </h1>`:p}
          <slot name="toolbar"></slot>
        </div>
      `:p}
      <div class="content">
        <slot></slot>
      </div>
    `,this.#t,{host:this})}},a=class extends HTMLElement{#t=this.attachShadow({mode:"open"});connectedCallback(){this.#e()}#e(){s(e`
      <style>${y}</style>
      <div class="section">
        <slot></slot>
      </div>
    `,this.#t,{host:this})}},l=class extends HTMLElement{#t=this.attachShadow({mode:"open"});connectedCallback(){this.#e()}#e(){s(e`
      <style>${u}</style>
      <div class="section-header">
        <slot></slot>
      </div>
    `,this.#t,{host:this})}},n=class extends HTMLElement{#t=this.attachShadow({mode:"open"});connectedCallback(){this.#e()}#e(){s(e`
      <style>${f}</style>
      <div class="section-divider">
      </div>
    `,this.#t,{host:this})}},d=class extends HTMLElement{#t=this.attachShadow({mode:"open"});connectedCallback(){this.#e()}#e(){s(e`
      <style>${m}</style>
      <div class="key"><slot></slot></div>
    `,this.#t,{host:this})}},c=class extends HTMLElement{#t=this.attachShadow({mode:"open"});connectedCallback(){this.#e()}#e(){s(e`
      <style>${g}</style>
      <div class="value"><slot></slot></div>
    `,this.#t,{host:this})}};customElements.define("devtools-report",i);customElements.define("devtools-report-section",a);customElements.define("devtools-report-section-header",l);customElements.define("devtools-report-key",d);customElements.define("devtools-report-value",c);customElements.define("devtools-report-divider",n);export{w as ReportView};
//# sourceMappingURL=report_view.js.map
