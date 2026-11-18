var p=Object.defineProperty;var c=(o,e)=>{for(var t in e)p(o,t,{get:e[t],enumerable:!0})};var d={};c(d,{ExpandableList:()=>s});import*as i from"../../lit/lit.js";import*as l from"../../visual_logging/visual_logging.js";var r=`:host{overflow:hidden}div{line-height:1.7em}.arrow-icon-button{cursor:pointer;padding:var(--sys-size-1) 0;border:none;background:none;margin-right:var(--sys-size-2)}.arrow-icon{display:inline-block;mask-image:var(--image-file-triangle-right);background-color:var(--icon-default);margin-top:var(--sys-size-2);height:var(--sys-size-7);width:var(--sys-size-7);transition:transform 200ms}.arrow-icon.expanded{transform:rotate(90deg)}.expandable-list-container{display:flex;margin-top:var(--sys-size-3)}.expandable-list-items{overflow:hidden}.link,
.devtools-link{color:var(--sys-color-primary);text-decoration:underline;cursor:pointer;outline-offset:var(--sys-size-2);border:none;background:none;font-family:inherit;font-size:var(--sys-typescale-body4-size);&:focus-visible{outline:var(--sys-size-2) solid var(--sys-color-state-focus-ring);outline-offset:0;border-radius:var(--sys-shape-corner-extra-small)}}button.link{border:none;background:none;font-family:inherit;font-size:inherit}.text-ellipsis{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
/*# sourceURL=${import.meta.resolve("./expandableList.css")} */`;var{html:a,Directives:{ifDefined:n}}=i,s=class extends HTMLElement{#a=this.attachShadow({mode:"open"});#e=!1;#i=[];#t;set data(e){this.#i=e.rows,this.#t=e.title,this.#s()}#o(){this.#e=!this.#e,this.#s()}#s(){this.#i.length<1||i.render(a`
      <style>${r}</style>
      <div class="expandable-list-container">
        <div>
          ${this.#i.length>1?a`
              <button title=${n(this.#t)} aria-label=${n(this.#t)} aria-expanded=${this.#e?"true":"false"} @click=${()=>this.#o()} class="arrow-icon-button">
                <span class="arrow-icon ${this.#e?"expanded":""}"
                jslog=${l.expand().track({click:!0})}></span>
              </button>
            `:i.nothing}
        </div>
        <div class="expandable-list-items">
          ${this.#i.filter((e,t)=>this.#e||t===0).map(e=>a`
            ${e}
          `)}
        </div>
      </div>
    `,this.#a,{host:this})}};customElements.define("devtools-expandable-list",s);export{d as ExpandableList};
//# sourceMappingURL=expandable_list.js.map
