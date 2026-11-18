var c=Object.defineProperty;var d=(s,e)=>{for(var o in e)c(s,o,{get:e[o],enumerable:!0})};var n={};d(n,{Switch:()=>r,SwitchChangeEvent:()=>t});import{html as h,nothing as a,render as b}from"../../lit/lit.js";import*as l from"../../visual_logging/visual_logging.js";var i=`:host{position:relative;display:inline-block;width:26px;height:var(--sys-size-8)}input{opacity:0%;width:0;height:0}.slider{box-sizing:border-box;position:absolute;cursor:pointer;left:0;top:0;width:100%;height:100%;background-color:var(--sys-color-surface-variant);border:1px solid var(--sys-color-outline);border-radius:var(--sys-shape-corner-full);transition:background-color 80ms linear}.slider::before{position:absolute;content:"";height:var(--sys-size-5);width:var(--sys-size-5);border-radius:var(--sys-shape-corner-full);top:calc(50% - 4px);left:3px;background-color:var(--sys-color-outline);transition:transform 80ms linear,background-color 80ms linear,width 80ms linear,height 80ms linear,top 80ms linear,left 80ms linear}input:focus-visible + .slider{outline:2px solid var(--sys-color-state-focus-ring);outline-offset:2px}input:checked{& + .slider{background-color:var(--sys-color-primary);border:1px solid var(--sys-color-primary)}& + .slider::before{left:11px;height:var(--sys-size-6);width:var(--sys-size-6);top:calc(50% - 6px);background-color:var(--sys-color-on-primary)}}input:disabled:not(:checked){& + .slider{background-color:transparent;border-color:var(--sys-color-state-disabled)}& + .slider::before{background-color:var(--sys-color-state-disabled)}}input:disabled:checked{& + .slider{background-color:var(--sys-color-state-disabled-container);border-color:transparent}& + .slider::before{background-color:var(--sys-color-surface)}}@media (forced-colors: active){.slider::before,
  input:checked + .slider::before{background-color:ButtonText}input:disabled:not(:checked) + .slider,
  input:disabled:checked + .slider{background-color:transparent;border-color:GrayText}input:disabled:not(:checked) + .slider::before,
  input:disabled:checked + .slider::before{background-color:GrayText}}
/*# sourceURL=${import.meta.resolve("./switch.css")} */`;var t=class s extends Event{constructor(o){super(s.eventName);this.checked=o}checked;static eventName="switchchange"},r=class extends HTMLElement{#i=this.attachShadow({mode:"open"});#e=!1;#t=!1;#s="";#r="";connectedCallback(){this.#o()}set checked(e){this.#e=e,this.#o()}get checked(){return this.#e}set disabled(e){this.#t=e,this.#o()}get disabled(){return this.#t}get jslogContext(){return this.#s}set jslogContext(e){this.#s=e,this.#o()}get label(){return this.#r}set label(e){this.#r=e,this.#o()}#a=e=>{this.#e=e.target.checked,this.dispatchEvent(new t(this.#e))};#o(){let e=this.#s&&l.toggle(this.#s).track({change:!0});b(h`
    <style>${i}</style>
    <label jslog=${e||a}>
      <input type="checkbox"
        aria-label=${this.#r||a}
        @change=${this.#a}
        ?disabled=${this.#t}
        .checked=${this.#e}
      >
      <span class="slider" @click=${o=>o.stopPropagation()}></span>
    </label>
    `,this.#i,{host:this})}};customElements.define("devtools-switch",r);export{n as Switch};
//# sourceMappingURL=switch.js.map
