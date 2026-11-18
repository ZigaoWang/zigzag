var kt=Object.defineProperty;var K=(r,e)=>{for(var t in e)kt(r,t,{get:e[t],enumerable:!0})};var De={};K(De,{CSSOverviewUnusedDeclarations:()=>z});import*as he from"../../core/i18n/i18n.js";var N={topAppliedToAStatically:"`Top` applied to a statically positioned element",leftAppliedToAStatically:"`Left` applied to a statically positioned element",rightAppliedToAStatically:"`Right` applied to a statically positioned element",bottomAppliedToAStatically:"`Bottom` applied to a statically positioned element",widthAppliedToAnInlineElement:"`Width` applied to an inline element",heightAppliedToAnInlineElement:"`Height` applied to an inline element",verticalAlignmentAppliedTo:"Vertical alignment applied to element which is neither `inline` nor `table-cell`"},$t=he.i18n.registerUIStrings("panels/css_overview/CSSOverviewUnusedDeclarations.ts",N),E=he.i18n.getLocalizedString.bind(void 0,$t),z=class{static add(e,t,o){let i=e.get(t)||[];i.push(o),e.set(t,i)}static checkForUnusedPositionValues(e,t,o,i,s,n,a,c){if(o[i]==="static"){if(o[s]!=="auto"){let p=E(N.topAppliedToAStatically);this.add(e,p,{declaration:`top: ${o[s]}`,nodeId:t})}if(o[n]!=="auto"){let p=E(N.leftAppliedToAStatically);this.add(e,p,{declaration:`left: ${o[n]}`,nodeId:t})}if(o[a]!=="auto"){let p=E(N.rightAppliedToAStatically);this.add(e,p,{declaration:`right: ${o[a]}`,nodeId:t})}if(o[c]!=="auto"){let p=E(N.bottomAppliedToAStatically);this.add(e,p,{declaration:`bottom: ${o[c]}`,nodeId:t})}}}static checkForUnusedWidthAndHeightValues(e,t,o,i,s,n){if(o[i]==="inline"){if(o[s]!=="auto"){let a=E(N.widthAppliedToAnInlineElement);this.add(e,a,{declaration:`width: ${o[s]}`,nodeId:t})}if(o[n]!=="auto"){let a=E(N.heightAppliedToAnInlineElement);this.add(e,a,{declaration:`height: ${o[n]}`,nodeId:t})}}}static checkForInvalidVerticalAlignment(e,t,o,i,s){if(!(!o[i]||o[i].startsWith("inline")||o[i].startsWith("table"))&&o[s]!=="baseline"){let n=E(N.verticalAlignmentAppliedTo);this.add(e,n,{declaration:`vertical-align: ${o[s]}`,nodeId:t})}}};var Pe={};K(Pe,{CSSOverviewModel:()=>W});import*as P from"../../core/common/common.js";import*as R from"../../core/sdk/sdk.js";import*as Te from"../../ui/legacy/components/color_picker/color_picker.js";var W=class extends R.SDKModel.SDKModel{#o;#t;#s;constructor(e){super(e),this.#o=e.runtimeAgent(),this.#t=e.cssAgent(),this.#s=e.domsnapshotAgent()}async getNodeStyleStats(){let e=new Map,t=new Map,o=new Map,i=new Map,s=new Map,n=new Map,a=new Map,c={computedStyles:["background-color","color","fill","border-top-width","border-top-color","border-bottom-width","border-bottom-color","border-left-width","border-left-color","border-right-width","border-right-color","font-family","font-size","font-weight","line-height","position","top","right","bottom","left","display","width","height","vertical-align"],includeTextColorOpacities:!0,includeBlendedBackgroundColors:!0},p=v=>v instanceof P.Color.Legacy?v.hasAlpha()?v.asString(P.Color.Format.HEXA):v.asString(P.Color.Format.HEX):v.asString(),h=(v,f,C)=>{if(v===-1)return;let ee=m[v];if(!ee)return;let V=P.Color.parse(ee);if(!V||V.asLegacyColor().rgba()[3]===0)return;let g=p(V);if(!g)return;let L=C.get(g)||new Set;return L.add(f),C.set(g,L),V},I=v=>new Set(["altglyph","circle","ellipse","path","polygon","polyline","rect","svg","text","textpath","tref","tspan"]).has(v.toLowerCase()),Q=v=>new Set(["iframe","video","embed","img"]).has(v.toLowerCase()),pe=(v,f)=>new Set(["tr","td","thead","tbody"]).has(v.toLowerCase())&&f.startsWith("table"),Z=0,{documents:at,strings:m}=await this.#s.invoke_captureSnapshot(c);for(let{nodes:v,layout:f}of at){Z+=f.nodeIndex.length;for(let C=0;C<f.styles.length;C++){let ee=f.styles[C],V=f.nodeIndex[C];if(!v.backendNodeId||!v.nodeName)continue;let g=v.backendNodeId[V],L=v.nodeName[V],[lt,dt,ct,ut,pt,mt,vt,gt,ht,ft,bt,me,te,oe,ke,wt,St,yt,Ct,xt,ve,It,Mt,$e]=ee;h(lt,g,e);let ge=h(dt,g,t);if(I(m[L])&&h(ct,g,i),m[ut]!=="0px"&&h(pt,g,s),m[mt]!=="0px"&&h(vt,g,s),m[gt]!=="0px"&&h(ht,g,s),m[ft]!=="0px"&&h(bt,g,s),me&&me!==-1){let $=m[me],y=n.get($)||new Map,se="font-size",re="font-weight",D="line-height",x=y.get(se)||new Map,T=y.get(re)||new Map,M=y.get(D)||new Map;if(te!==-1){let w=m[te],A=x.get(w)||[];A.push(g),x.set(w,A)}if(oe!==-1){let w=m[oe],A=T.get(w)||[];A.push(g),T.set(w,A)}if(ke!==-1){let w=m[ke],A=M.get(w)||[];A.push(g),M.set(w,A)}y.set(se,x),y.set(re,T),y.set(D,M),n.set($,y)}let G=ge&&f.blendedBackgroundColors&&f.blendedBackgroundColors[C]!==-1?P.Color.parse(m[f.blendedBackgroundColors[C]]):null;if(ge&&G){let $=new Te.ContrastInfo.ContrastInfo({backgroundColors:[G.asString(P.Color.Format.HEXA)],computedFontSize:te!==-1?m[te]:"",computedFontWeight:oe!==-1?m[oe]:""}),y=ge.asLegacyColor().blendWithAlpha(f.textColorOpacities?f.textColorOpacities[C]:1);$.setColor(y);let se=p(y),re=p(G.asLegacyColor()),D=`${se}_${re}`;if(P.Settings.Settings.instance().resolve(R.SDKSettings.apcaSettingDescriptor).get()){let x=$.contrastRatioAPCA(),T=$.contrastRatioAPCAThreshold();if(!(x&&T?Math.abs(x)>=T:!1)&&x){let w={nodeId:g,contrastRatio:x,textColor:y,backgroundColor:G,thresholdsViolated:{aa:!1,aaa:!1,apca:!0}};o.has(D)?o.get(D).push(w):o.set(D,[w])}}else{let x=$.contrastRatioThreshold("aa")||0,T=$.contrastRatioThreshold("aaa")||0,M=$.contrastRatio()||0;if(x>M||T>M){let w={nodeId:g,contrastRatio:M,textColor:y,backgroundColor:G,thresholdsViolated:{aa:x>M,aaa:T>M,apca:!1}};o.has(D)?o.get(D).push(w):o.set(D,[w])}}}z.checkForUnusedPositionValues(a,g,m,wt,St,xt,yt,Ct),!I(m[L])&&!Q(m[L])&&z.checkForUnusedWidthAndHeightValues(a,g,m,ve,It,Mt),$e!==-1&&!pe(m[L],m[ve])&&z.checkForInvalidVerticalAlignment(a,g,m,ve,$e)}}return{backgroundColors:e,textColors:t,textColorContrastIssues:o,fillColors:i,borderColors:s,fontInfo:n,unusedDeclarations:a,elementCount:Z}}getComputedStyleForNode(e){return this.#t.invoke_getComputedStyleForNode({nodeId:e})}async getMediaQueries(){let e=await this.#t.invoke_getMediaQueries(),t=new Map;if(!e)return t;for(let o of e.medias){if(o.source==="linkedSheet")continue;let i=t.get(o.text)||[];i.push(o),t.set(o.text,i)}return t}async getGlobalStylesheetStats(){let e=`(function() {
      let styleRules = 0;
      let inlineStyles = 0;
      let externalSheets = 0;
      const stats = {
        // Simple.
        type: new Set(),
        class: new Set(),
        id: new Set(),
        universal: new Set(),
        attribute: new Set(),

        // Non-simple.
        nonSimple: new Set()
      };

      for (const styleSheet of document.styleSheets) {
        if (styleSheet.href) {
          externalSheets++;
        } else {
          inlineStyles++;
        }

        // Attempting to grab rules can trigger a DOMException.
        // Try it and if it fails skip to the next stylesheet.
        let rules;
        try {
          rules = styleSheet.rules;
        } catch (err) {
          continue;
        }

        for (const rule of rules) {
          if ('selectorText' in rule) {
            styleRules++;

            // Each group that was used.
            for (const selectorGroup of rule.selectorText.split(',')) {
              // Each selector in the group.
              for (const selector of selectorGroup.split(/[\\t\\n\\f\\r ]+/g)) {
                if (selector.startsWith('.')) {
                  // Class.
                  stats.class.add(selector);
                } else if (selector.startsWith('#')) {
                  // Id.
                  stats.id.add(selector);
                } else if (selector.startsWith('*')) {
                  // Universal.
                  stats.universal.add(selector);
                } else if (selector.startsWith('[')) {
                  // Attribute.
                  stats.attribute.add(selector);
                } else {
                  // Type or non-simple selector.
                  const specialChars = /[#.:\\[\\]|\\+>~]/;
                  if (specialChars.test(selector)) {
                    stats.nonSimple.add(selector);
                  } else {
                    stats.type.add(selector);
                  }
                }
              }
            }
          }
        }
      }

      return {
        styleRules,
        inlineStyles,
        externalSheets,
        stats: {
          // Simple.
          type: stats.type.size,
          class: stats.class.size,
          id: stats.id.size,
          universal: stats.universal.size,
          attribute: stats.attribute.size,

          // Non-simple.
          nonSimple: stats.nonSimple.size
        }
      }
    })()`,{result:t}=await this.#o.invoke_evaluate({expression:e,returnByValue:!0});if(t.type==="object")return t.value}};R.SDKModel.SDKModel.register(W,{capabilities:R.Target.Capability.DOM,autostart:!1});var Le={};K(Le,{CSSOverviewProcessingView:()=>X,DEFAULT_VIEW:()=>Ve});import*as fe from"../../core/i18n/i18n.js";import*as Ne from"../../ui/components/buttons/buttons.js";import*as Ue from"../../ui/legacy/legacy.js";import{html as Dt,render as Tt}from"../../ui/lit/lit.js";var Ae=`.overview-processing-view{overflow:hidden;padding:var(--sys-size-8);justify-content:center;align-items:center;height:100%}.overview-processing-view h1{font-size:var(--sys-typescale-body1-size);text-align:center;font-weight:normal;margin:0;padding:var(--sys-size-5)}.overview-processing-view h2{font-size:var(--sys-typescale-body4-size);text-align:center;font-weight:normal;margin:0;padding-top:var(--sys-size-13)}
/*# sourceURL=${import.meta.resolve("./cssOverviewProcessingView.css")} */`;var Oe={cancel:"Cancel"},Pt=fe.i18n.registerUIStrings("panels/css_overview/CSSOverviewProcessingView.ts",Oe),At=fe.i18n.getLocalizedString.bind(void 0,Pt),Ve=(r,e,t)=>{Tt(Dt`
    <style>${Ae}</style>
    <div style="overflow:auto">
      <div class="vbox overview-processing-view">
        <h1>Processing page</h1>
        <div>
          <devtools-button
              @click=${r.onCancel}
              .jslogContext=${"css-overview.cancel-processing"}
              .variant=${Ne.Button.Variant.OUTLINED}>${At(Oe.cancel)}</devtools-button>
        </div>
      </div>
    </div>`,t)},X=class extends Ue.Widget.Widget{#o=()=>{};#t;constructor(e,t=Ve){super(e),this.#t=t,this.requestUpdate()}set onCancel(e){this.#o=e,this.requestUpdate()}performUpdate(){this.#t({onCancel:this.#o},{},this.element)}};var et={};K(et,{CSSOverviewCompletedView:()=>F,DEFAULT_VIEW:()=>Je,ELEMENT_DETAILS_DEFAULT_VIEW:()=>Ze,ElementDetailsView:()=>ae});import"../../ui/legacy/components/data_grid/data_grid.js";import"../../ui/kit/kit.js";import*as S from"../../core/common/common.js";import*as Se from"../../core/i18n/i18n.js";import*as _e from"../../core/platform/platform.js";import*as U from"../../core/sdk/sdk.js";import*as qe from"../../core/text_utils/text_utils.js";import*as Qe from"../../ui/geometry/geometry.js";import*as Ge from"../../ui/legacy/components/utils/utils.js";import*as B from"../../ui/legacy/legacy.js";import{Directives as Lt,html as u,nothing as k,render as Xe}from"../../ui/lit/lit.js";import*as b from"../../ui/visual_logging/visual_logging.js";import*as Ye from"../common/common.js";var ie=`@scope to (devtools-widget > *){.overview-completed-view{overflow:auto;--overview-default-padding:var(--sys-size-12);--overview-icon-padding:var(--sys-size-13)}.overview-completed-view .summary ul,
  .overview-completed-view .colors ul{display:flex;flex-wrap:wrap;list-style:none;margin:0;padding:0}.overview-completed-view .summary ul{display:grid;grid-template-columns:repeat(auto-fill,140px);gap:var(--sys-size-8)}.overview-completed-view .colors ul li{display:inline-block;margin:0 0 var(--sys-size-8);padding:0 var(--sys-size-5) 0 0}.overview-completed-view .summary ul li{display:flex;flex-direction:column;grid-column-start:auto}.overview-completed-view li .label{font-size:var(--sys-typescale-body4-size);padding-bottom:var(--sys-size-2)}.overview-completed-view li .value{font-size:17px}.overview-completed-view ul li span{font-weight:bold}.unused-rules-grid .header-container,
  .unused-rules-grid .data-container,
  .unused-rules-grid table.data{position:relative}.unused-rules-grid .data-container{top:0;max-height:350px}.unused-rules-grid{border-left:none;border-right:none}.unused-rules-grid .monospace{display:block;height:18px}.element-grid{flex:1;border-left:none;border-right:none;overflow:auto}.block{width:65px;height:25px;border-radius:3px;margin-right:var(--sys-size-8);&:focus-visible{outline:var(--sys-size-2) solid var(--sys-color-state-focus-ring);outline-offset:var(--sys-size-2)}}.block-title{padding-top:var(--sys-size-3);font-size:var(--sys-typescale-body4-size);color:var(--sys-color-on-surface);letter-spacing:0;text-transform:uppercase}.block-title.color-text{text-transform:none;max-width:65px;text-overflow:ellipsis;white-space:nowrap;cursor:text;user-select:text;overflow:hidden}.results-section{flex-shrink:0;border-bottom:var(--sys-size-1) solid var(--sys-color-divider);padding:var(--overview-default-padding) 0 var(--overview-default-padding) 0}.horizontally-padded{padding-left:var(--overview-default-padding);padding-right:var(--overview-default-padding)}.results-section h1{font-size:15px;font-weight:normal;padding:0;margin:0 0 var(--sys-size-9);padding-left:calc(var(--overview-default-padding) + var(--overview-icon-padding));position:relative;height:26px;line-height:26px}.results-section h1::before{content:"";display:block;position:absolute;left:var(--overview-default-padding);top:0;width:26px;height:26px;background-image:var(--image-file-cssoverview_icons_2x);background-size:104px 26px}.results-section.horizontally-padded h1{padding-left:var(--overview-icon-padding)}.results-section.horizontally-padded h1::before{left:0}.results-section.summary h1{padding-left:0}.results-section.summary h1::before{display:none}.results-section.colors h1::before{background-position:0 0}.results-section.font-info h1::before{background-position:-26px 0}.results-section.unused-declarations h1::before{background-position:-52px 0}.results-section.media-queries h1::before{background-position:-78px 0}.results-section.colors h2{margin-top:var(--sys-size-9);font-size:var(--sys-typescale-body3-size);font-weight:normal}.overview-completed-view .font-info ul,
  .overview-completed-view .media-queries ul,
  .overview-completed-view .unused-declarations ul{width:100%;list-style:none;margin:0;padding:0 var(--overview-default-padding)}.overview-completed-view .font-info ul li,
  .overview-completed-view .media-queries ul li,
  .overview-completed-view .unused-declarations ul li{display:grid;grid-template-columns:2fr 3fr;gap:var(--sys-size-6);margin-bottom:var(--sys-size-3);align-items:center}.overview-completed-view .font-info button .details,
  .overview-completed-view .media-queries button .details,
  .overview-completed-view .unused-declarations button .details{min-width:100px;text-align:right;margin-right:var(--sys-size-5);color:var(--sys-color-primary);pointer-events:none}.overview-completed-view .font-info button .bar-container,
  .overview-completed-view .media-queries button .bar-container,
  .overview-completed-view .unused-declarations button .bar-container{flex:1;pointer-events:none}.overview-completed-view .font-info button .bar,
  .overview-completed-view .media-queries button .bar,
  .overview-completed-view .unused-declarations button .bar{height:var(--sys-size-5);background:var(--sys-color-primary-bright);border-radius:var(--sys-size-2);min-width:var(--sys-size-2)}.overview-completed-view .font-info button,
  .overview-completed-view .media-queries button,
  .overview-completed-view .unused-declarations button{border:none;padding:0;padding-right:10px;margin:0;display:flex;align-items:center;border-radius:var(--sys-size-2);cursor:pointer;height:var(--sys-size-12);background:none;&:focus-visible{outline:var(--sys-size-2) solid var(--sys-color-state-focus-ring)}&:hover{border-radius:var(--sys-shape-corner-medium-small);background:var(--sys-color-state-hover-on-subtle)}&:hover .details,
    &:focus .details{color:color-mix(in srgb,var(--sys-color-primary),var(--sys-color-state-hover-on-prominent) 6%)}&:hover .bar,
    &:focus .bar{background-color:color-mix(in srgb,var(--sys-color-primary-bright),var(--sys-color-state-hover-on-prominent) 6%);color:var(--sys-color-on-primary)}}.overview-completed-view .font-info .font-metric{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:var(--sys-size-6)}.overview-completed-view .font-info ul{padding:0}.overview-completed-view .font-info ul li{grid-template-columns:1fr 4fr}.overview-completed-view .font-info h2{font-size:var(--sys-typescale-body2-size);font-weight:bold;margin:0 0 1em}.overview-completed-view .font-info h3{font-size:var(--sys-typescale-body3-size);font-weight:normal;font-style:italic;margin:0 0 0.5em}.overview-completed-view .font-info{padding-bottom:0}.overview-completed-view .font-family{padding:var(--overview-default-padding)}.overview-completed-view .font-family:nth-child(2n+1){background:var(--sys-color-cdt-base-container)}.overview-completed-view .font-family:first-of-type{padding-top:0}.contrast-warning{display:flex;align-items:center;margin-top:var(--sys-size-2)}.contrast-warning .threshold-label{font-weight:normal;width:30px}.contrast-warning devtools-icon{margin-left:var(--sys-size-2)}.contrast-preview{padding:0 5px}.contrast-container-in-grid{display:flex;align-items:center}.contrast-container-in-grid > *{margin-right:5px;min-width:initial}::part(node-id-column){align-items:center;height:var(--sys-size-9);--show-element-display:none}::part(node-id-column):focus,
  ::part(node-id-column):hover{--show-element-display:inline-block}::part(show-element){display:var(--show-element-display);height:var(--sys-size-8);width:var(--sys-size-8)}.results-section.colors{forced-color-adjust:none}}
/*# sourceURL=${import.meta.resolve("./cssOverviewCompletedView.css")} */`;var We={};K(We,{CSSOverviewSidebarPanel:()=>Y,DEFAULT_VIEW:()=>Ke});import"../../ui/legacy/legacy.js";import*as we from"../../core/i18n/i18n.js";import*as Be from"../../ui/components/buttons/buttons.js";import*as Fe from"../../ui/legacy/legacy.js";import{Directives as Nt,html as ze,render as Ut}from"../../ui/lit/lit.js";import*as He from"../../ui/visual_logging/visual_logging.js";var Ee=`@scope to (devtools-widget > *){.overview-sidebar-panel{display:flex;background:var(--sys-color-cdt-base-container);min-width:fit-content;flex-direction:column}.overview-sidebar-panel-item{height:30px;padding-left:30px;display:flex;align-items:center;color:var(--sys-color-on-surface);white-space:nowrap;&:hover{background:var(--sys-color-state-hover-on-subtle)}&:focus{background:var(--sys-color-state-focus-highlight)}&.selected{background:var(--sys-color-tonal-container);color:var(--sys-color-on-tonal-container)}}.overview-toolbar{border-bottom:var(--sys-size-1) solid var(--sys-color-divider);flex:0 0 auto}.overview-sidebar-panel-item:focus-visible{outline-width:unset}@media (forced-colors: active){.overview-sidebar-panel-item.selected{forced-color-adjust:none;background:Highlight;color:HighlightText}.overview-sidebar-panel-item:hover{forced-color-adjust:none;background:Highlight;color:HighlightText}}}
/*# sourceURL=${import.meta.resolve("./cssOverviewSidebarPanel.css")} */`;var{classMap:Ot}=Nt,be={clearOverview:"Clear overview",cssOverviewPanelSidebar:"CSS overview panel sidebar"},Vt=we.i18n.registerUIStrings("panels/css_overview/CSSOverviewSidebarPanel.ts",be),Re=we.i18n.getLocalizedString.bind(void 0,Vt),Ke=(r,e,t)=>{Ut(ze`
      <style>${Ee}</style>
      <div class="overview-sidebar-panel" @click=${s=>{if(s.target instanceof HTMLElement){let n=s.target.dataset.id;n&&r.onItemClick(n)}}} @keydown=${s=>{if(!(s.key!=="Enter"&&s.key!=="ArrowUp"&&s.key!=="ArrowDown")){if(s.target instanceof HTMLElement){let n=s.target.dataset.id;n&&r.onItemKeyDown(n,s.key)}s.consume(!0)}}}
           aria-label=${Re(be.cssOverviewPanelSidebar)} role="tree">
        <div class="overview-toolbar">
          <devtools-toolbar>
            <devtools-button title=${Re(be.clearOverview)} @click=${r.onReset}
                .iconName=${"clear"} .variant=${Be.Button.Variant.TOOLBAR}
                .jslogContext=${"css-overview.clear-overview"}></devtools-button>
          </devtools-toolbar>
        </div>
        ${r.items.map(({id:s,name:n})=>{let a=s===r.selectedId;return ze`
            <div class="overview-sidebar-panel-item ${Ot({selected:a})}"
                ?autofocus=${a}
                role="treeitem" data-id=${s} tabindex="0"
                jslog=${He.item(`css-overview.${s}`).track({click:!0,keydown:"Enter|ArrowUp|ArrowDown"})}>
              ${n}
            </div>`})}
      </div>`,t)},Y=class extends Fe.Widget.VBox{#o;#t=[];#s;#r=(e,t)=>{};#i=()=>{};constructor(e,t=Ke){super(e,{useShadowDom:!0,delegatesFocus:!0}),this.#o=t}performUpdate(){let e={items:this.#t,selectedId:this.#s,onReset:this.#i,onItemClick:this.#a.bind(this),onItemKeyDown:this.#n.bind(this)};this.#o(e,{},this.contentElement)}set items(e){this.#t=e,this.requestUpdate()}set selectedId(e){this.#e(e)}set onItemSelected(e){this.#r=e,this.requestUpdate()}set onReset(e){this.#i=e,this.requestUpdate()}#e(e,t=!1){return this.#s=e,this.requestUpdate(),this.#r(e,t),this.updateComplete}#a(e){this.#e(e,!1)}#n(e,t){if(t==="Enter")this.#e(e,!0);else{let o=-1;for(let a=0;a<this.#t.length;a++)if(this.#t[a].id===e){o=a;break}if(o<0)return;let s=(o+(t==="ArrowDown"?1:-1))%this.#t.length,n=this.#t[s].id;if(!n)return;this.#e(n,!1).then(()=>{this.element.blur(),this.element.focus()})}}};var{styleMap:le,ref:J}=Lt,{widget:je}=B.Widget,l={overviewSummary:"Overview summary",colors:"Colors",fontInfo:"Font info",unusedDeclarations:"Unused declarations",mediaQueries:"Media queries",elements:"Elements",externalStylesheets:"External stylesheets",inlineStyleElements:"Inline style elements",styleRules:"Style rules",typeSelectors:"Type selectors",idSelectors:"ID selectors",classSelectors:"Class selectors",universalSelectors:"Universal selectors",attributeSelectors:"Attribute selectors",nonsimpleSelectors:"Non-simple selectors",backgroundColorsS:"Background colors: {PH1}",textColorsS:"Text colors: {PH1}",fillColorsS:"Fill colors: {PH1}",borderColorsS:"Border colors: {PH1}",thereAreNoFonts:"No fonts",thereAreNoUnusedDeclarations:"No unused declarations",thereAreNoMediaQueries:"No media queries",contrastIssues:"Contrast issues",nOccurrences:"{n, plural, =1 {# occurrence} other {# occurrences}}",contrastIssuesS:"Contrast issues: {PH1}",textColorSOverSBackgroundResults:"Text color {PH1} over {PH2} background results in low contrast for {PH3} elements",aa:"AA",aaa:"AAA",apca:"APCA",element:"Element",declaration:"Declaration",source:"Source",contrastRatio:"Contrast ratio",cssOverviewElements:"CSS overview elements",showElement:"Show element",unableToLink:"(unable to link)",unableToLinkToInlineStyle:"(unable to link to inline style)"},Et=Se.i18n.registerUIStrings("panels/css_overview/CSSOverviewCompletedView.ts",l),d=Se.i18n.getLocalizedString.bind(void 0,Et);function ye(r){let{h:e,s:t,l:o}=r.as(S.Color.Format.HSL);return e=Math.round(e*360),t=Math.round(t*100),o=Math.round(o*100),o=Math.max(0,o-15),`1px solid hsl(${e}deg ${t}% ${o}%)`}var zt=new Intl.NumberFormat("en-US"),Je=(r,e,t)=>{function o(i,s){i&&(i.scrollIntoView(),s&&i.querySelector('button, [tabindex="0"]')?.focus())}Xe(u`
      <style>${ie}</style>
      <devtools-split-view direction="column" sidebar-position="first" sidebar-initial-size="200">
        <devtools-widget slot="sidebar" ${je(Y,{minimumSize:new Qe.Size(100,25),items:[{name:d(l.overviewSummary),id:"summary"},{name:d(l.colors),id:"colors"},{name:d(l.fontInfo),id:"font-info"},{name:d(l.unusedDeclarations),id:"unused-declarations"},{name:d(l.mediaQueries),id:"media-queries"}],selectedId:r.selectedSection,onItemSelected:r.onSectionSelected,onReset:r.onReset})}>
        </devtools-widget>
        <devtools-split-view sidebar-position="second" slot="main" direction="row" sidebar-initial-size="minimized">
          <div class="vbox overview-completed-view" slot="main" @click=${r.onClick}>
            <!-- Dupe the styles into the main container because of the shadow root will prevent outer styles. -->
            <style>${ie}</style>
            <div class="results-section horizontally-padded summary"
                  jslog=${b.section("summary")}
                  ${J(i=>{e.revealSection.set("summary",o.bind(null,i))})}>
              <h1>${d(l.overviewSummary)}</h1>
              ${Rt(r.elementCount,r.globalStyleStats,r.mediaQueries)}
            </div>
            <div class="results-section horizontally-padded colors"
                jslog=${b.section("colors")}
                ${J(i=>{e.revealSection.set("colors",o.bind(null,i))})}>
                <h1>${d(l.colors)}</h1>
                ${Bt(r.backgroundColors,r.textColors,r.textColorContrastIssues,r.fillColors,r.borderColors)}
              </div>
              <div class="results-section font-info"
                    jslog=${b.section("font-info")}
                    ${J(i=>{e.revealSection.set("font-info",o.bind(null,i))})}>
                <h1>${d(l.fontInfo)}</h1>
                ${Kt(r.fontInfo)}
              </div>
              <div class="results-section unused-declarations"
                    jslog=${b.section("unused-declarations")}
                    ${J(i=>{e.revealSection.set("unused-declarations",o.bind(null,i))})}>
                <h1>${d(l.unusedDeclarations)}</h1>
                ${Ft(r.unusedDeclarations)}
              </div>
              <div class="results-section media-queries"
                    jslog=${b.section("media-queries")}
                    ${J(i=>{e.revealSection.set("media-queries",o.bind(null,i))})}>
              <h1>${d(l.mediaQueries)}</h1>
              ${Ht(r.mediaQueries)}
            </div>
          </div>
          <devtools-widget slot="sidebar" ${je(i=>{let s=new B.TabbedPane.TabbedPane(i);return e.closeAllTabs=()=>{s.closeTabs(s.tabIds())},e.addTab=(n,a,c,p)=>{s.hasTab(n)||s.appendTab(n,a,c,void 0,void 0,!0,void 0,void 0,p),s.selectTab(n),s.parentWidget().setSidebarMinimized(!1)},s.addEventListener(B.TabbedPane.Events.TabClosed,n=>{s.tabIds().length===0&&s.parentWidget().setSidebarMinimized(!0)}),s})}>
          </devtools-widget>
        </devtools-split-view>
      </devtools-split-view>`,t)};function Rt(r,e,t){let o=(i,s)=>u`
    <li jslog=${b.item("summary-item")}>
      <div class="label">${i}</div>
      <div class="value">${zt.format(s)}</div>
    </li>`;return u`<ul>
    ${o(d(l.elements),r)}
    ${o(d(l.externalStylesheets),e.externalSheets)}
    ${o(d(l.inlineStyleElements),e.inlineStyles)}
    ${o(d(l.styleRules),e.styleRules)}
    ${o(d(l.mediaQueries),t.length)}
    ${o(d(l.typeSelectors),e.stats.type)}
    ${o(d(l.idSelectors),e.stats.id)}
    ${o(d(l.classSelectors),e.stats.class)}
    ${o(d(l.universalSelectors),e.stats.universal)}
    ${o(d(l.attributeSelectors),e.stats.attribute)}
    ${o(d(l.nonsimpleSelectors),e.stats.nonSimple)}
  </ul>`}function Bt(r,e,t,o,i){return u`
    <h2>${d(l.backgroundColorsS,{PH1:r.length})}</h2>
    <ul>${r.map(s=>ne("background",s))}</ul>

    <h2>${d(l.textColorsS,{PH1:e.length})}</h2>
    <ul>${e.map(s=>ne("text",s))}</ul>

    ${t.size>0?jt(t):""}

    <h2>${d(l.fillColorsS,{PH1:o.length})}</h2>
    <ul>${o.map(s=>ne("fill",s))}</ul>

    <h2>${d(l.borderColorsS,{PH1:i.length})}</h2>
    <ul>${i.map(s=>ne("border",s))}</ul>`}function Ft(r){return r.length>0?Ce(r,"unused-declarations"):u`<div class="horizontally-padded">${d(l.thereAreNoUnusedDeclarations)}</div>`}function Ht(r){return r.length>0?Ce(r,"media-queries"):u`<div class="horizontally-padded">${d(l.thereAreNoMediaQueries)}</div>`}function Kt(r){return r.length>0?u`${r.map(({font:e,fontMetrics:t})=>u`
    <section class="font-family">
      <h2>${e}</h2>
      ${Wt(e,t)}
    </section>`)}`:u`<div>${d(l.thereAreNoFonts)}</div>`}function Wt(r,e){return u`
    <div class="font-metric">
      ${e.map(({label:t,values:o})=>u`
        <div>
          <h3>${t}</h3>
          ${Ce(o,"font-info",`${r}/${t}`,t)}
        </div>`)}
    </div>`}function Ce(r,e,t="",o=""){let i=r.reduce((s,n)=>s+n.nodes.length,0);return u`
      <ul aria-label=${e}>
        ${r.map(({title:s,nodes:n})=>{let a=100*n.length/i,c=d(l.nOccurrences,{n:n.length});return u`<li jslog=${b.item("css-overview.group-item")}>
            <div class="title">${s}</div>
            <button data-type=${e} data-path=${t} data-label=${s}
            jslog=${b.action().track({click:!0}).context(`css-overview.${e}`)}
            aria-label=${`${o?`${o}, `:""}${s}: ${c}`}>
              <div class="details">${c}</div>
              <div class="bar-container">
                <div class="bar" style=${le({width:a})}></div>
              </div>
            </button>
          </li>`})}
  </ul>`}function jt(r){return u`
    <h2>${d(l.contrastIssuesS,{PH1:r.size})}</h2>
    <ul>
      ${[...r.entries()].map(([e,t])=>_t(e,t))}
    </ul>`}function _t(r,e){console.assert(e.length>0);let t=e[0];for(let c of e)Math.abs(c.contrastRatio)<Math.abs(t.contrastRatio)&&(t=c);let o=t.textColor.asString(S.Color.Format.HEXA),i=t.backgroundColor.asString(S.Color.Format.HEXA),s=S.Settings.Settings.instance().resolve(U.SDKSettings.apcaSettingDescriptor).get(),n=d(l.textColorSOverSBackgroundResults,{PH1:o,PH2:i,PH3:e.length}),a=ye(t.backgroundColor.asLegacyColor());return u`<li jslog=${b.item("contrast-issue")}>
    <button
      title=${n} aria-label=${n}
      data-type="contrast" data-key=${r} data-section="contrast" class="block"
      style=${le({color:o,backgroundColor:i,border:a})}
      jslog=${b.action("css-overview.contrast").track({click:!0})}>
      Text
    </button>
    <div class="block-title">
      ${s?u`
        <div class="contrast-warning hidden">
          <span class="threshold-label">${d(l.apca)}</span>
          ${t.thresholdsViolated.apca?j():_()}
        </div>`:u`
        <div class="contrast-warning hidden">
          <span class="threshold-label">${d(l.aa)}</span>
          ${t.thresholdsViolated.aa?j():_()}
        </div>
        <div class="contrast-warning hidden">
          <span class="threshold-label">${d(l.aaa)}</span>
          ${t.thresholdsViolated.aaa?j():_()}
        </div>`}
    </div>
  </li>`}function ne(r,e){let t=S.Color.parse(e)?.asLegacyColor();return t?u`<li jslog=${b.item("color-item")}>
    <button title=${e} data-type="color" data-color=${e}
      data-section=${r} class="block"
      style=${le({backgroundColor:e,border:ye(t)})}
      jslog=${b.action("css-overview.color").track({click:!0})}>
    </button>
    <div class="block-title color-text">${e}</div>
  </li>`:k}var F=class r extends B.Widget.VBox{onReset=()=>{};#o="summary";#t;#s;#r;#i;#e;#a;#n={revealSection:new Map,closeAllTabs:()=>{},addTab:(e,t,o,i)=>{}};constructor(e,t=Je){super(e),this.#a=t,this.registerRequiredCSS(ie),this.#r=new Ge.Linkifier.Linkifier(20,!0),this.#i=new Map,this.#e=null}set target(e){if(!e)return;let t=e.model(U.CSSModel.CSSModel),o=e.model(U.DOMModel.DOMModel);if(!t||!o)throw new Error("Target must provide CSS and DOM models");this.#t=t,this.#s=o}#c(e,t){let o=this.#n.revealSection.get(e);o&&o(t)}#u(){this.#p(),this.onReset()}#p(){this.#n.closeAllTabs(),this.#i=new Map,r.pushedNodes.clear(),this.#o="summary",this.requestUpdate()}#m(e){if(!e.target)return;let o=e.target.dataset,i=o.type;if(!i||!this.#e)return;let s;switch(i){case"contrast":{let n=o.section,a=o.key;if(!a)return;let c=this.#e.textColorContrastIssues.get(a)||[];s={type:i,key:a,nodes:c,section:n};break}case"color":{let n=o.color,a=o.section;if(!n)return;let c;switch(a){case"text":c=this.#e.textColors.get(n);break;case"background":c=this.#e.backgroundColors.get(n);break;case"fill":c=this.#e.fillColors.get(n);break;case"border":c=this.#e.borderColors.get(n);break}if(!c)return;c=Array.from(c).map(p=>({nodeId:p})),s={type:i,color:n,nodes:c,section:a};break}case"unused-declarations":{let n=o.label;if(!n)return;let a=this.#e.unusedDeclarations.get(n);if(!a)return;s={type:i,declaration:n,nodes:a};break}case"media-queries":{let n=o.label;if(!n)return;let a=this.#e.mediaQueries.get(n);if(!a)return;s={type:i,text:n,nodes:a};break}case"font-info":{let n=o.label;if(!o.path)return;let[a,c]=o.path.split("/");if(!n)return;let p=this.#e.fontInfo.get(a);if(!p)return;let h=p.get(c);if(!h)return;let I=h.get(n);if(!I)return;let Q=I.map(Z=>({nodeId:Z})),pe=`${n} (${a}, ${c})`;s={type:i,name:pe,nodes:Q};break}default:return}e.consume(),this.#d(s),this.requestUpdate()}performUpdate(){if(!this.#e||!("backgroundColors"in this.#e)||!("textColors"in this.#e))return;let e={elementCount:this.#e.elementCount,backgroundColors:this.#l(this.#e.backgroundColors),textColors:this.#l(this.#e.textColors),textColorContrastIssues:this.#e.textColorContrastIssues,fillColors:this.#l(this.#e.fillColors),borderColors:this.#l(this.#e.borderColors),globalStyleStats:this.#e.globalStyleStats,mediaQueries:this.#v(this.#e.mediaQueries),unusedDeclarations:this.#v(this.#e.unusedDeclarations),fontInfo:this.#h(this.#e.fontInfo),selectedSection:this.#o,onClick:this.#m.bind(this),onSectionSelected:this.#c.bind(this),onReset:this.#u.bind(this)};this.#a(e,this.#n,this.element)}#d(e){let t="",o="";switch(e.type){case"contrast":{let{section:s,key:n}=e;t=`${s}-${n}`,o=d(l.contrastIssues);break}case"color":{let{section:s,color:n}=e;t=`${s}-${n}`,o=`${n.toUpperCase()} (${s})`;break}case"unused-declarations":{let{declaration:s}=e;t=`${s}`,o=`${s}`;break}case"media-queries":{let{text:s}=e;t=`${s}`,o=`${s}`;break}case"font-info":{let{name:s}=e;t=`${s}`,o=`${s}`;break}}let i=this.#i.get(t);if(!i){if(!this.#s||!this.#t)throw new Error("Unable to initialize CSS overview, missing models");i=new ae(this.#s,this.#t,this.#r),i.data=e.nodes,this.#i.set(t,i)}this.#n.addTab(t,o,i,e.type)}#l(e){return Array.from(e.keys()).sort((t,o)=>{let i=S.Color.parse(t)?.asLegacyColor(),s=S.Color.parse(o)?.asLegacyColor();return!i||!s?0:S.ColorUtils.luminance(s.rgba())-S.ColorUtils.luminance(i.rgba())})}#h(e){return Array.from(e.entries()).map(([o,i])=>{let s=Array.from(i.entries());return{font:o,fontMetrics:s.map(([n,a])=>({label:n,values:this.#v(a)}))}})}#v(e){return Array.from(e.entries()).sort((t,o)=>{let i=t[1];return o[1].length-i.length}).map(([t,o])=>({title:t,nodes:o}))}set overviewData(e){this.#e=e,this.requestUpdate()}static pushedNodes=new Set},Ze=(r,e,t)=>{let{items:o,visibility:i}=r;Xe(u`
    <div>
      <devtools-data-grid class="element-grid" striped inline
         name=${d(l.cssOverviewElements)}>
        <table>
          <tr>
            ${i.has("node-id")?u`
              <th id="node-id" weight="50" sortable>
                ${d(l.element)}
              </th>`:k}
            ${i.has("declaration")?u`
              <th id="declaration" weight="50" sortable>
                ${d(l.declaration)}
              </th>`:k}
            ${i.has("source-url")?u`
              <th id="source-url" weight="100">
                ${d(l.source)}
              </th>`:k}
            ${i.has("contrast-ratio")?u`
              <th id="contrast-ratio" weight="25" width="150px" sortable fixed>
                ${d(l.contrastRatio)}
              </th>`:k}
          </tr>
          ${o.map(({data:s,link:n,showNode:a})=>u`
            <tr>
              ${i.has("node-id")?qt(s,n,a):k}
              ${i.has("declaration")?Qt(s):k}
              ${i.has("source-url")?Gt(s,n):k}
              ${i.has("contrast-ratio")?Xt(s):k}
            </tr>`)}
        </table>
      </devtools-data-grid>
    </div>`,t)},ae=class extends B.Widget.Widget{#o;#t;#s;#r;#i;constructor(e,t,o,i=Ze){super(),this.#o=e,this.#t=t,this.#s=o,this.#i=i,this.#r=[]}set data(e){this.#r=e,this.requestUpdate()}async performUpdate(){let e=new Set;if(!this.#r.length){this.#i({items:[],visibility:e},{},this.element);return}let[t]=this.#r;"nodeId"in t&&t.nodeId&&e.add("node-id"),"declaration"in t&&t.declaration&&e.add("declaration"),"sourceURL"in t&&t.sourceURL&&e.add("source-url"),"contrastRatio"in t&&t.contrastRatio&&e.add("contrast-ratio");let o;if("nodeId"in t&&e.has("node-id")){let s=this.#r.reduce((n,a)=>{let c=a.nodeId;return F.pushedNodes.has(c)?n:(F.pushedNodes.add(c),n.add(c))},new Set);o=await this.#o.pushNodesByBackendIdsToFrontend(s)}let i=await Promise.all(this.#r.map(async s=>{let n,a;if("nodeId"in s&&e.has("node-id")){let c=o?.get(s.nodeId)??null;c&&(n=Ye.DOMLinkifier.Linkifier.instance().linkify(c),a=()=>c.scrollIntoView())}if("range"in s&&s.range&&s.styleSheetId&&e.has("source-url")){let c=qe.TextRange.TextRange.fromObject(s.range),p=this.#t.styleSheetHeaderForId(s.styleSheetId);if(p){let h=p.lineNumberInSource(c.startLine),I=p.columnNumberInSource(c.startLine,c.startColumn),Q=new U.CSSModel.CSSLocation(p,h,I);n=u`${this.#s.linkifyCSSLocation(Q)}`}}return{data:s,link:n,showNode:a}}));this.#i({items:i,visibility:e},{},this.element)}};function qt(r,e,t){return e?u`
    <td>
      ${e}
      <devtools-icon part="show-element" name="select-element"
          title=${d(l.showElement)} tabindex="0"
          @click=${()=>t?.()}></devtools-icon>
    </td>`:k}function Qt(r){if(!("declaration"in r))throw new Error("Declaration entry is missing a declaration.");return u`<td>${r.declaration}</td>`}function Gt(r,e){return"range"in r&&r.range?e?u`<td>${e}</td>`:u`<td>${d(l.unableToLink)}</td>`:u`<td>${d(l.unableToLinkToInlineStyle)}</td>`}function Xt(r){if(!("contrastRatio"in r))throw new Error("Contrast ratio entry is missing a contrast ratio.");let e=S.Settings.Settings.instance().resolve(U.SDKSettings.apcaSettingDescriptor).get(),t=_e.NumberUtilities.floor(r.contrastRatio,2),o=e?t+"%":t,i=ye(r.backgroundColor),s=r.textColor.asString(),n=r.backgroundColor.asString();return u`
    <td>
      <div class="contrast-container-in-grid">
          <span class="contrast-preview" style=${le({border:i,color:s,backgroundColor:n})}>Aa</span>
          <span>${o}</span>
          ${e?u`
            <span>${d(l.apca)}</span>${r.thresholdsViolated.apca?j():_()}`:u`
            <span>${d(l.aa)}</span>${r.thresholdsViolated.aa?j():_()}
            <span>${d(l.aaa)}</span>${r.thresholdsViolated.aaa?j():_()}`}
      </div>
    </td>`}function j(){return u`
    <devtools-icon name="clear" class="small" style="color:var(--icon-error);"></devtools-icon>`}function _(){return u`
    <devtools-icon name="checkmark" class="small"
        style="color:var(--icon-checkmark-green);"></devtools-icon>`}var nt={};K(nt,{CSSOverviewPanel:()=>Me,DEFAULT_VIEW:()=>it});import*as ce from"../../core/host/host.js";import*as O from"../../core/sdk/sdk.js";import*as ue from"../../ui/legacy/legacy.js";import{render as oo}from"../../ui/lit/lit.js";import"../../ui/components/panel_feedback/panel_feedback.js";import"../../ui/components/panel_introduction_steps/panel_introduction_steps.js";import*as xe from"../../core/i18n/i18n.js";import*as st from"../../ui/components/buttons/buttons.js";import*as rt from"../../ui/legacy/legacy.js";import{html as Yt,render as Jt}from"../../ui/lit/lit.js";var tt=`@scope to (devtools-widget > *){h1{font-weight:normal}.css-overview-start-view{padding:var(--sys-size-11);display:flex;flex-direction:column;background-color:var(--sys-color-cdt-base-container);overflow:auto}.start-capture-wrapper{width:fit-content}.preview-feature{padding:var(--sys-size-6) var(--sys-size-8);border:var(--sys-size-1) solid var(--sys-color-neutral-outline);color:var(--sys-color-on-surface);font-size:var(--sys-typescale-body3-size);line-height:var(--sys-typescale-body3-line-height);border-radius:var(--sys-shape-corner-medium-small);margin:42px 0;letter-spacing:0.01em}.preview-header{color:var(--sys-color-primary);font-size:var(--sys-typescale-body3-size);line-height:var(--sys-typescale-body3-line-height);letter-spacing:0.01em;margin:9px 0 var(--sys-size-7)}.preview-icon{vertical-align:middle}.feedback-prompt{margin-bottom:var(--sys-size-11)}.feedback-prompt .devtools-link{color:-webkit-link;cursor:pointer;text-decoration:underline}.resources{display:flex;flex-direction:row}.thumbnail-wrapper{width:var(--sys-size-22);height:92px;margin-right:var(--sys-size-9)}.video-doc-header{font-size:var(--sys-typescale-body3-size);line-height:var(--sys-typescale-body3-line-height);letter-spacing:0.04em;color:var(--sys-color-on-surface);margin-bottom:var(--sys-size-2)}devtools-feedback-button{align-self:flex-end}.resources .devtools-link{font-size:var(--sys-typescale-body2-size);line-height:var(--sys-size-10);letter-spacing:0.04em;text-decoration-line:underline;color:var(--sys-color-primary)}}
/*# sourceURL=${import.meta.resolve("./cssOverviewStartView.css")} */`;var H={captureOverview:"Capture overview",identifyCSSImprovements:"Identify potential CSS improvements",capturePageCSSOverview:"Capture an overview of your page\u2019s CSS",identifyCSSImprovementsWithExampleIssues:"Identify potential CSS improvements (e.g. low contrast issues, unused declarations, color or font mismatches)",locateAffectedElements:"Locate the affected elements in the Elements panel",quickStartWithCSSOverview:"Quick start: get started with the new CSS overview panel"},Zt=xe.i18n.registerUIStrings("panels/css_overview/CSSOverviewStartView.ts",H),q=xe.i18n.getLocalizedString.bind(void 0,Zt),ot="https://g.co/devtools/css-overview-feedback",eo="https://developer.chrome.com/docs/devtools/css-overview",to=(r,e,t)=>{Jt(Yt`
    <style>${tt}</style>
    <div class="css-overview-start-view">
      <devtools-panel-introduction-steps>
        <span slot="title">${q(H.identifyCSSImprovements)}</span>
        <span slot="step-1">${q(H.capturePageCSSOverview)}</span>
        <span slot="step-2">${q(H.identifyCSSImprovementsWithExampleIssues)}</span>
        <span slot="step-3">${q(H.locateAffectedElements)}</span>
      </devtools-panel-introduction-steps>
      <div class="start-capture-wrapper">
        <devtools-button
          class="start-capture"
          autofocus
          .variant=${st.Button.Variant.PRIMARY}
          .jslogContext=${"css-overview.capture-overview"}
          @click=${r.onStartCapture}>
          ${q(H.captureOverview)}
        </devtools-button>
      </div>
      <devtools-panel-feedback .data=${{feedbackUrl:ot,quickStartUrl:eo,quickStartLinkText:q(H.quickStartWithCSSOverview)}}>
      </devtools-panel-feedback>
      <devtools-feedback-button .data=${{feedbackUrl:ot}}>
      </devtools-feedback-button>
    </div>`,t)},de=class extends rt.Widget.Widget{#o;onStartCapture=()=>{};constructor(e,t=to){super(e,{useShadowDom:!0,delegatesFocus:!0}),this.#o=t,this.performUpdate()}performUpdate(){this.#o({onStartCapture:this.onStartCapture},{},this.contentElement)}};var{widget:Ie}=ue.Widget,it=(r,e,t)=>{oo(r.state==="start"?Ie(de,{onStartCapture:r.onStartCapture}):r.state==="processing"?Ie(X,{onCancel:r.onCancel}):Ie(F,{onReset:r.onReset,overviewData:r.overviewData,target:r.target}),t)},Me=class extends ue.Panel.Panel{#o;#t;#s;#r;#i;#e;#a;#n;#c;#u;#p;#m;#d;#l;constructor(e=it){super("css-overview"),this.#o=O.TargetManager.TargetManager.instance().inspectedURL(),O.TargetManager.TargetManager.instance().addEventListener(O.TargetManager.Events.INSPECTED_URL_CHANGED,this.#v,this),this.#l=e,O.TargetManager.TargetManager.instance().observeTargets(this),this.#g()}#h(){ce.userMetrics.actionTaken(ce.UserMetrics.Action.CaptureCssOverviewClicked),this.#y()}#v(){this.#o!==O.TargetManager.TargetManager.instance().inspectedURL()&&(this.#o=O.TargetManager.TargetManager.instance().inspectedURL(),this.#g())}targetAdded(e){e===O.TargetManager.TargetManager.instance().primaryPageTarget()&&(this.#t=e.model(W)??void 0)}targetRemoved(){}#f(){if(!this.#t)throw new Error("Did not retrieve model information yet.");return this.#t}#g(){this.#s=new Map,this.#r=new Map,this.#i=new Map,this.#e=new Map,this.#a=new Map,this.#n=new Map,this.#c=new Map,this.#u=0,this.#p={styleRules:0,inlineStyles:0,externalSheets:0,stats:{type:0,class:0,id:0,universal:0,attribute:0,nonSimple:0}},this.#m=new Map,this.#b()}#b(){this.#d="start",this.performUpdate()}#w(){this.#d="processing",this.performUpdate()}#S(){this.#d="completed",this.performUpdate()}performUpdate(){let e={state:this.#d,onStartCapture:this.#h.bind(this),onCancel:this.#g.bind(this),onReset:this.#g.bind(this),target:this.#t?.target(),overviewData:{backgroundColors:this.#s,textColors:this.#r,textColorContrastIssues:this.#m,fillColors:this.#i,borderColors:this.#e,globalStyleStats:this.#p,fontInfo:this.#a,elementCount:this.#u,mediaQueries:this.#n,unusedDeclarations:this.#c}};this.#l(e,{},this.contentElement)}async#y(){this.#w();let e=this.#f(),[t,{elementCount:o,backgroundColors:i,textColors:s,textColorContrastIssues:n,fillColors:a,borderColors:c,fontInfo:p,unusedDeclarations:h},I]=await Promise.all([e.getGlobalStylesheetStats(),e.getNodeStyleStats(),e.getMediaQueries()]);o&&(this.#u=o),t&&(this.#p=t),I&&(this.#n=I),i&&(this.#s=i),s&&(this.#r=s),n&&(this.#m=n),a&&(this.#i=a),c&&(this.#e=c),p&&(this.#a=p),h&&(this.#c=h),this.#S()}};export{et as CSSOverviewCompletedView,Pe as CSSOverviewModel,nt as CSSOverviewPanel,Le as CSSOverviewProcessingView,We as CSSOverviewSidebarPanel,De as CSSOverviewUnusedDeclarations};
//# sourceMappingURL=css_overview.js.map
