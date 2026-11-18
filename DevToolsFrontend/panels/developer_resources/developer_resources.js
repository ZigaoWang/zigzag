var V=Object.defineProperty;var C=(r,t)=>{for(var s in t)V(r,s,{get:t[s],enumerable:!0})};var M={};C(M,{DEFAULT_VIEW:()=>T,DeveloperResourcesRevealer:()=>L,DeveloperResourcesView:()=>S});import"../../ui/legacy/legacy.js";import*as P from"../../core/i18n/i18n.js";import*as $ from"../../core/platform/platform.js";import*as x from"../../core/sdk/sdk.js";import*as n from"../../ui/legacy/legacy.js";import{html as z,render as _}from"../../ui/lit/lit.js";import*as R from"../../ui/visual_logging/visual_logging.js";import"../../ui/legacy/components/data_grid/data_grid.js";import"../../ui/components/highlighting/highlighting.js";import*as y from"../../core/host/host.js";import*as c from"../../core/i18n/i18n.js";import*as b from"../../core/platform/platform.js";import*as g from"../../core/sdk/sdk.js";import*as f from"../../ui/legacy/legacy.js";import{html as h,nothing as l,render as E}from"../../ui/lit/lit.js";var U=`@scope to (devtools-widget > *){.data-grid{border:none}::part(url-outer){width:100%;display:inline-flex;justify-content:flex-start}::part(filter-highlight){font-weight:bold}::part(url-prefix){overflow-x:hidden;text-overflow:ellipsis}::part(url-suffix){flex:none}}
/*# sourceURL=${import.meta.resolve("./developerResourcesListView.css")} */`;var i={status:"Status",url:"URL",initiator:"Initiator",totalBytes:"Total bytes",duration:"Duration",error:"Error",developerResources:"Developer resources",copyUrl:"Copy URL",copyInitiatorUrl:"Copy initiator URL",pending:"Pending",success:"Success",failure:"Failure",sBytes:"{n, plural, =1 {# byte} other {# bytes}}",numberOfResourceMatch:"{n, plural, =1 {# resource matches} other {# resources match}}",noResourceMatches:"No resource matches"},K=c.i18n.registerUIStrings("panels/developer_resources/DeveloperResourcesListView.ts",i),a=c.i18n.getLocalizedString.bind(void 0,K),{withThousandsSeparator:F}=b.NumberUtilities,H=(r,t,s)=>{function o(e,d){if(!e)return"";let u=r.filters.find(D=>D.key?.split(",")?.includes(d));if(!u?.regex)return"";let w=u.regex.exec(e);return w?.length?`${w.index},${w[0].length}`:""}E(h`
      <style>${U}</style>
      <devtools-data-grid name=${a(i.developerResources)} striped class="flex-auto"
         .filters=${r.filters} @contextmenu=${r.onContextMenu} @selected=${r.onSelect}>
        <table>
          <tr>
            <th id="status" sortable fixed width="60px">
              ${a(i.status)}
            </th>
            <th id="url" sortable width="250px">
              ${a(i.url)}
            </th>
            <th id="initiator" sortable width="80px">
              ${a(i.initiator)}
            </th>
            <th id="size" sortable fixed width="80px" align="right">
              ${a(i.totalBytes)}
            </th>
            <th id="duration" sortable fixed width="80px" align="right">
              ${a(i.duration)}
            </th>
            <th id="error-message" sortable width="200px">
              ${a(i.error)}
            </th>
          </tr>
          ${r.items.map((e,d)=>{let u=/^(.*)(\/[^/]*)$/.exec(e.url);return h`
            <tr selected=${e===r.selectedItem||l}
                data-url=${e.url??l}
                data-initiator-url=${e.initiator.initiatorUrl??l}
                data-index=${d}>
              <td>${e.success===!0?a(i.success):e.success===!1?a(i.failure):a(i.pending)}</td>
              <td title=${e.url} aria-label=${e.url}>
                <devtools-highlight aria-hidden="true" part="url-outer"
                                    ranges=${o(e.url,"url")}>
                  <div part="url-prefix">${u?u[1]:e.url}</div>
                  <div part="url-suffix">${u?u[2]:""}</div>
                </devtools-highlight>
              </td>
              <td title=${e.initiator.initiatorUrl||""}
                  aria-label=${e.initiator.initiatorUrl||""}
                  @mouseenter=${()=>r.onInitiatorMouseEnter(e.initiator.frameId)}
                  @mouseleave=${r.onInitiatorMouseLeave}
              >${e.initiator.initiatorUrl||""}</td>
              <td aria-label=${e.size!==null?a(i.sBytes,{n:e.size}):l}
                  data-value=${e.size??l}>${e.size!==null?h`<span>${F(e.size)}</span>`:""}</td>
              <td aria-label=${e.duration!==null?c.TimeUtilities.millisToString(e.duration):l}
                  data-value=${e.duration??l}>${e.duration!==null?h`<span>${c.TimeUtilities.millisToString(e.duration)}</span>`:""}</td>
              <td class="error-message">
                ${e.errorMessage?h`
                <devtools-highlight ranges=${o(e.errorMessage,"error-message")}>
                  ${e.errorMessage}
                </devtools-highlight>`:l}
              </td>
            </tr>`})}
          </table>
        </devtools-data-grid>`,s)},v=class extends f.Widget.VBox{#e=[];#t=null;#r=null;#o;#s=[];constructor(t,s=H){super(t,{useShadowDom:!0}),this.#o=s}set selectedItem(t){this.#t=t,this.requestUpdate()}set onSelect(t){this.#r=t}#i(t,s){let o=s.dataset.url;o&&t.clipboardSection().appendItem(a(i.copyUrl),()=>{y.InspectorFrontendHost.InspectorFrontendHostInstance.copyText(o)},{jslogContext:"copy-url"});let e=s.dataset.initiatorUrl;e&&t.clipboardSection().appendItem(a(i.copyInitiatorUrl),()=>{y.InspectorFrontendHost.InspectorFrontendHostInstance.copyText(e)},{jslogContext:"copy-initiator-url"})}set items(t){this.#e=[...t],this.requestUpdate()}reset(){this.items=[],this.requestUpdate()}set filters(t){this.#s=t,this.requestUpdate(),this.updateComplete.then(()=>{let s=Number(this.contentElement.querySelector("devtools-data-grid")?.getAttribute("aria-rowcount"))??0,o="";s===0?o=a(i.noResourceMatches):o=a(i.numberOfResourceMatch,{n:s}),f.ARIAUtils.LiveAnnouncer.alert(o)})}performUpdate(){let t={items:this.#e,selectedItem:this.#t,filters:this.#s,onContextMenu:o=>{o.detail?.element&&this.#i(o.detail.menu,o.detail.element)},onSelect:o=>{this.#t=o.detail?this.#e[Number(o.detail.dataset.index)]:null,this.#r?.(this.#t)},onInitiatorMouseEnter:o=>{let e=o?g.FrameManager.FrameManager.instance().getFrame(o):null;e&&e.highlight()},onInitiatorMouseLeave:()=>{g.OverlayModel.OverlayModel.hideDOMNodeHighlight(g.TargetManager.TargetManager.instance())}},s={};this.#o(t,s,this.contentElement)}};var I=`@scope to (devtools-widget > *){:scope{overflow:hidden}.developer-resource-view-toolbar-container{display:flex;border-bottom:var(--sys-size-1) solid var(--sys-color-divider);flex:0 0 auto}.developer-resource-view-toolbar{width:100%}.developer-resource-view-toolbar-summary{background-color:var(--sys-color-cdt-base-container);border-top:var(--sys-size-1) solid var(--sys-color-divider);padding-left:5px;flex:0 0 19px;display:flex;padding-right:5px}.developer-resource-view-toolbar-summary .developer-resource-view-message{padding-top:var(--sys-size-2);padding-left:1ex;text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.developer-resource-view-results{overflow-y:auto;display:flex;flex:auto}}
/*# sourceURL=${import.meta.resolve("./developerResourcesView.css")} */`;var{widget:j}=n.Widget,{bindToSetting:q}=n.UIUtils,p={filterByText:"Filter by URL and error",loadHttpsDeveloperResources:"Load HTTP(S) developer resources through the website you inspect, not through DevTools",enableLoadingThroughTarget:"Load through website",resourcesCurrentlyLoading:"{PH1} resources, {PH2} currently loading",resources:"{n, plural, =1 {# resource} other {# resources}}"},B=P.i18n.registerUIStrings("panels/developer_resources/DeveloperResourcesView.ts",p),m=P.i18n.getLocalizedString.bind(void 0,B),L=class{async reveal(t){let o=x.PageResourceLoader.PageResourceLoader.instance().getResourcesLoaded().get(t.key);if(o)return await n.ViewManager.ViewManager.instance().showView("developer-resources"),await(await n.ViewManager.ViewManager.instance().view("developer-resources").widget()).select(o)}},T=(r,t,s)=>{_(z`
    <style>
      ${I}
    </style>
    <div class="vbox flex-auto" jslog=${R.panel("developer-resources").track({resize:!0})}>
      <div class="developer-resource-view-toolbar-container" jslog=${R.toolbar()}
          role="toolbar">
        <devtools-toolbar class="developer-resource-view-toolbar" role="presentation">
          <devtools-toolbar-input type="filter" placeholder=${m(p.filterByText)}
              @change=${r.onFilterChanged} style="flex-grow:1">
          </devtools-toolbar-input>
          <devtools-checkbox
              title=${m(p.loadHttpsDeveloperResources)}
              ${q(r.loadThroughTargetSetting)}>
            ${m(p.enableLoadingThroughTarget)}
          </devtools-checkbox>
        </devtools-toolbar>
      </div>
      <div class="developer-resource-view-results">
        ${j(v,{items:r.items,selectedItem:r.selectedItem,onSelect:r.onSelect,filters:r.filters})}
      </div>
      <div class="developer-resource-view-toolbar-summary">
        <div class="developer-resource-view-message">
          ${r.numLoading>0?m(p.resourcesCurrentlyLoading,{PH1:r.numResources,PH2:r.numLoading}):m(p.resources,{n:r.numResources})}
         </div>
      </div>
    </div>`,s)},S=class extends n.Widget.VBox{#e;#t;#r=null;#o=[];constructor(t=T){super({useShadowDom:!0}),this.#t=t,this.#e=x.PageResourceLoader.PageResourceLoader.instance(),this.#e.addEventListener(x.PageResourceLoader.Events.UPDATE,this.requestUpdate,this),this.requestUpdate()}async performUpdate(){let{loading:t,resources:s}=this.#e.getScopedNumberOfResources(),o={onFilterChanged:d=>{this.onFilterChanged(d.detail)},items:this.#e.getResourcesLoaded().values(),selectedItem:this.#r,onSelect:d=>{this.#r=d},filters:this.#o,numResources:s,numLoading:t,loadThroughTargetSetting:this.#e.getLoadThroughTargetSetting()},e={};this.#t(o,e,this.contentElement)}async select(t){await this.updateComplete,this.#r=t,this.requestUpdate()}async selectedItem(){return await this.updateComplete,this.#r}onFilterChanged(t){let s=t?$.StringUtilities.createPlainTextSearchRegex(t,"i"):null;s?this.#o=[{key:"url,error-message",regex:s,negative:!1}]:this.#o=[],this.requestUpdate()}};export{M as DeveloperResourcesView};
//# sourceMappingURL=developer_resources.js.map
