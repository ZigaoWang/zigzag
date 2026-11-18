var k=Object.defineProperty;var S=(m,t)=>{for(var e in t)k(m,e,{get:t[e],enumerable:!0})};var x={};S(x,{SettingCheckbox:()=>l});import"../tooltips/tooltips.js";import"../../kit/kit.js";import*as b from"../../../core/host/host.js";import*as g from"../../../core/i18n/i18n.js";import*as s from"../../lit/lit.js";import*as c from"../../settings/settings.js";import*as v from"../../visual_logging/visual_logging.js";import*as d from"../buttons/buttons.js";import*as f from"../input/input.js";var p=`:host{padding:0;margin:0}input{height:var(--sys-size-6);width:var(--sys-size-6);min-height:var(--sys-size-6);min-width:var(--sys-size-6);margin:var(--sys-size-4)}label{display:inline-flex;align-items:center;overflow:hidden;text-overflow:ellipsis}p{margin:var(--sys-size-4) 0}.info-icon{cursor:pointer;position:relative;margin-left:var(--sys-size-2);top:var(--sys-size-2);width:var(--sys-size-9);height:var(--sys-size-9)}.link{color:var(--text-link);text-decoration:underline}
/*# sourceURL=${import.meta.resolve("./settingCheckbox.css")} */`;var{html:a}=s,h={learnMore:"Learn more"},y=g.i18n.registerUIStrings("ui/components/settings/SettingCheckbox.ts",h),u=g.i18n.getLocalizedString.bind(void 0,y),l=class extends HTMLElement{#s=this.attachShadow({mode:"open"});#t;#e;#i;#o;set data(t){this.#e&&this.#t&&this.#t.removeChangeListener(this.#e.listener),this.#t=t.setting,this.#i=t.textOverride,this.#o=t.disabled,this.#e=this.#t.addChangeListener(()=>{this.#n()}),this.#n()}icon(){if(!this.#t)return;let e=c.SettingUIRegistration.maybeResolve(this.#t.descriptor())?.learnMore;if(e){let n=`${this.#t.name}-documentation`,i={iconName:"info",variant:d.Button.Variant.ICON,size:d.Button.Size.SMALL,jslogContext:n},o=e.url;if(e.tooltip){let r=`${this.#t.name}-information`;return a`
          <devtools-button
            class="info-icon"
            aria-details=${r}
            aria-disabled=true
            accessibleLabel=${e.tooltip()}
            .data=${i}
          ></devtools-button>
          <devtools-tooltip id=${r} variant="rich">
            <span>${e.tooltip()}</span><br />
            ${o?a`<devtools-link
                  href=${o}
                  class="link"
                  .jslogContext=${n}
                  >${u(h.learnMore)}</devtools-link
                >`:s.nothing}
          </devtools-tooltip>
        `}if(o){let r=$=>{b.InspectorFrontendHost.InspectorFrontendHostInstance.openInNewTab(o),$.consume()};return i.iconName="help",i.title=u(h.learnMore),a`<devtools-button
          class="info-icon"
          @click=${r}
          .data=${i}
        ></devtools-button>`}}}get checked(){return this.#t?this.#t.get():!1}#n(){if(!this.#t)throw new Error('No "Setting" object provided for rendering');let t=c.SettingUIRegistration.maybeResolve(this.#t.descriptor()),e=t?.learnMore,n=t?.title??"",i=this.icon(),o=e?.tooltip?.()??"";s.render(a`
      <style>${f.checkboxStyles}</style>
      <style>${p}</style>
      <p>
        <label title=${o}>
          <input
            type="checkbox"
            .checked=${this.checked}
            ?disabled=${this.#o}
            @change=${this.#r}
            jslog=${v.toggle().track({change:!0}).context(this.#t.name)}
            aria-label=${n}
          />
          ${this.#i||n}
        </label>
        ${i}
      </p>`,this.#s,{host:this})}#r(t){this.#t?.set(t.target.checked),this.dispatchEvent(new CustomEvent("change",{bubbles:!0,composed:!1}))}};customElements.define("setting-checkbox",l);export{x as SettingCheckbox};
//# sourceMappingURL=settings.js.map
