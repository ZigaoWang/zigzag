var o=Object.defineProperty;var c=(i,e)=>{for(var t in e)o(i,t,{get:e[t],enumerable:!0})};var a={};c(a,{Spinner:()=>r});import{Directives as d,html as m,render as l}from"../../lit/lit.js";var n=`:host{overflow:hidden;width:var(--sys-size-7);height:var(--sys-size-7);display:inline-block;font-size:0;letter-spacing:0;white-space:nowrap}:host([active]){animation:spinner-container-animation 1.5s linear infinite}.spinner{height:100%;width:100%}.spinner.indeterminate{animation:indeterminate-spinner-animation 5332ms cubic-bezier(0.4,0,0.2,1) infinite both}.spinner circle{stroke:var(--sys-color-state-disabled);stroke-width:var(--sys-size-6);fill:transparent;transform-origin:50% 50%;transform:rotate(-90deg)}.spinner.indeterminate circle{stroke:var(--sys-color-primary);stroke-dasharray:100,100;stroke-dashoffset:0;animation:indeterminate-spinner-circle-animation 1333ms cubic-bezier(0.4,0,0.2,1) infinite both}@keyframes spinner-container-animation{100%{transform:rotate(360deg)}}@keyframes indeterminate-spinner-animation{12.5%{transform:rotate(135deg)}25%{transform:rotate(270deg)}37.5%{transform:rotate(405deg)}50%{transform:rotate(540deg)}62.5%{transform:rotate(675deg)}75%{transform:rotate(810deg)}87.5%{transform:rotate(945deg)}100%{transform:rotate(1080deg)}}@keyframes indeterminate-spinner-circle-animation{0%{stroke-dasharray:5,100;stroke-dashoffset:0;transform:rotate(-90deg)}50%{stroke-dasharray:75,100;stroke-dashoffset:0;transform:rotate(-225deg)}100%{stroke-dasharray:5,100;stroke-dashoffset:0;transform:rotate(-90deg)}}
/*# sourceURL=${import.meta.resolve("./spinner.css")} */`;var{classMap:f}=d,r=class extends HTMLElement{static observedAttributes=["active"];#t=this.attachShadow({mode:"open"});constructor(e){super(),this.active=e?.active??!0}attributeChangedCallback(e,t,s){t!==s&&e==="active"&&this.#e()}get active(){return this.hasAttribute("active")}set active(e){this.toggleAttribute("active",e)}connectedCallback(){this.#e()}#e(){let e={indeterminate:this.active,spinner:!0};l(m`
        <style>
          ${n}
        </style>
        <svg
          class=${f(e)}
          viewBox="0 0 100 100"
        >
          <circle
            cx="50"
            cy="50"
            r="44"
            pathLength="100"
          ></circle>
        </svg>
      `,this.#t,{host:this})}};customElements.define("devtools-spinner",r);export{a as Spinner};
//# sourceMappingURL=spinners.js.map
