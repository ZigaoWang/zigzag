var M=Object.defineProperty;var P=(D,e)=>{for(var o in e)M(D,o,{get:e[o],enumerable:!0})};var B={};P(B,{CookiesTable:()=>K});import"../data_grid/data_grid.js";import"../../../components/buttons/buttons.js";import*as S from"../../../../core/common/common.js";import*as m from"../../../../core/i18n/i18n.js";import*as f from"../../../../core/root/root.js";import*as t from"../../../../core/sdk/sdk.js";import*as c from"../../../../models/issues_manager/issues_manager.js";import*as A from"../../../../panels/network/forward/forward.js";import{Icon as R}from"../../../kit/kit.js";import{Directives as U,html as k,nothing as y,render as O}from"../../../lit/lit.js";import*as x from"../../legacy.js";var T=`.data-grid-data-grid-node .ai-button-container{display:none;float:right;devtools-floating-button{position:absolute;z-index:999;margin-left:-17px}}.data-grid-data-grid-node:hover .ai-button-container{display:inline-flex}
/*# sourceURL=${import.meta.resolve("./dataGridAiButton.css")} */`;var I=`devtools-data-grid{flex:auto}.cookies-table devtools-icon{margin-right:var(--sys-size-3)}
/*# sourceURL=${import.meta.resolve("./cookiesTable.css")} */`;var{repeat:_,ifDefined:E}=U,r={session:"Session",name:"Name",value:"Value",size:"Size",domain:"Domain",path:"Path",secure:"Secure",partitionKeySite:"Partition key site",priority:"Priority",editableCookies:"Editable cookies",cookies:"Cookies",na:"N/A",showRequestsWithThisCookie:"Show requests with this cookie",showIssueAssociatedWithThis:"Show issue associated with this cookie",sourcePortTooltip:"Shows the source port (range 1-65535) the cookie was set on. If the port is unknown, this shows -1.",sourceSchemeTooltip:"Shows the source scheme (`Secure`, `NonSecure`) the cookie was set on. If the scheme is unknown, this shows `Unset`.",timeAfter:"after {date}",timeAfterTooltip:"The expiration timestamp is {seconds}, which corresponds to a date after {date}",opaquePartitionKey:"(opaque)",httpOnlyCookiesCannotBeAdded:"HttpOnly cookies can\u2019t be added as context"},w=m.i18n.registerUIStrings("ui/legacy/components/cookie_table/CookiesTable.ts",r),l=m.i18n.getLocalizedString.bind(void 0,w),N=m.i18n.getLazilyComputedLocalizedString.bind(void 0,w),g=N(r.session);function $(D){return D===t.Cookie.Attribute.HTTP_ONLY||D===t.Cookie.Attribute.SECURE}var K=class extends x.Widget.VBox{#i;#o;#n;#e;#t=!1;#r;#l;#d;lastEditedColumnId;data=[];cookies=[];#s;cookieToBlockedReasons;cookieToExemptionReason;view;selectedKey;#a;renderInline;schemeBindingEnabled;portBindingEnabled;constructor(e,o,a,i,C,u,d){super(e),d||(d=(n,L,v)=>{O(k`
          <devtools-data-grid
               name=${n.editable?l(r.editableCookies):l(r.cookies)}
               id="cookies-table"
               striped
               ?inline=${n.renderInline}
               ?deletable=${n.deletable}
               @create=${s=>n.onCreate(s.detail)}
               @refresh=${n.onRefresh}
               @deselect=${()=>n.onSelect(void 0)}
          >
            <table>
              ${n.showAiButton?k`<style>${T}</style>`:y}
               <tr>
                 <th id=${t.Cookie.Attribute.NAME} sortable ?disclosure=${n.editable} ?editable=${n.editable} long weight="24">
                   ${l(r.name)}
                 </th>
                 <th id=${t.Cookie.Attribute.VALUE} sortable ?editable=${n.editable} long weight="34">
                   ${l(r.value)}
                 </th>
                 <th id=${t.Cookie.Attribute.DOMAIN} sortable weight="7" ?editable=${n.editable}>
                   ${l(r.domain)}
                 </th>
                 <th id=${t.Cookie.Attribute.PATH} sortable weight="7" ?editable=${n.editable}>
                   ${l(r.path)}
                 </th>
                 <th id=${t.Cookie.Attribute.EXPIRES} sortable weight="7" ?editable=${n.editable}>
                   Expires / Max-Age
                 </th>
                 <th id=${t.Cookie.Attribute.SIZE} sortable align="right" weight="7">
                   ${l(r.size)}
                 </th>
                 <th id=${t.Cookie.Attribute.HTTP_ONLY} sortable align="center" weight="7" ?editable=${n.editable} type="boolean">
                   HttpOnly
                 </th>
                 <th id=${t.Cookie.Attribute.SECURE} sortable align="center" weight="7" ?editable=${n.editable} type="boolean">
                   ${l(r.secure)}
                 </th>
                 <th id=${t.Cookie.Attribute.SAME_SITE} sortable weight="7" ?editable=${n.editable}>
                   SameSite
                 </th>
                 <th id=${t.Cookie.Attribute.PARTITION_KEY_SITE} sortable weight="7" ?editable=${n.editable}>
                   ${l(r.partitionKeySite)}
                 </th>
                 <th id=${t.Cookie.Attribute.HAS_CROSS_SITE_ANCESTOR} sortable align="center" weight="7" ?editable=${n.editable} type="boolean">
                   Cross Site
                 </th>
                 <th id=${t.Cookie.Attribute.PRIORITY} sortable weight="7" ?editable=${n.editable}>
                   ${l(r.priority)}
                 </th>
                 ${n.schemeBindingEnabled?k`
                 <th id=${t.Cookie.Attribute.SOURCE_SCHEME} sortable align="center" weight="7" ?editable=${n.editable} type="string">
                   SourceScheme
                 </th>`:""}
                 ${n.portBindingEnabled?k`
                <th id=${t.Cookie.Attribute.SOURCE_PORT} sortable align="center" weight="7" ?editable=${n.editable} type="number">
                   SourcePort
                </th>`:""}
              </tr>
              ${_(this.data,s=>s.key,s=>{let p=!!s["http-only"];return k`
                <tr ?selected=${s.key===n.selectedKey}
                    ?inactive=${s.inactive}
                    ?dirty=${s.dirty}
                    ?highlighted=${s.flagged}
                    @edit=${b=>n.onEdit(s,b.detail.columnId,b.detail.valueBeforeEditing,b.detail.newText)}
                    @delete=${()=>n.onDelete(s)}
                    @contextmenu=${b=>n.onContextMenu(s,b.detail)}
                    @select=${()=>n.onSelect(s.key)}>
                  <td>${n.showAiButton?k`
                      <span class="ai-button-container">
                        <devtools-floating-button
                          icon-name=${f.Runtime.hostConfig.devToolsGeminiRebranding?.enabled?"spark":"smart-assistant"}
                          title=${E(p?l(r.httpOnlyCookiesCannotBeAdded):n.aiButtonTitle)}
                          ?disabled=${p}
                          @click=${b=>!p&&n.onAiButtonClick?.(s,b)}
                        ></devtools-floating-button>
                      </span>
                    `:y}${s.icons?.name}${s.name}</td>
                  <td>${s.value}</td>
                  <td>${s.icons?.domain}${s.domain}</td>
                  <td>${s.icons?.path}${s.path}</td>
                  <td title=${E(s.expiresTooltip)}>${s.expires}</td>
                  <td>${s.size}</td>
                  <td data-value=${p}></td>
                  <td data-value=${!!s.secure}>${s.icons?.secure}</td>
                  <td>${s.icons?.["same-site"]}${s["same-site"]}</td>
                  <td>${s["partition-key-site"]}</td>
                  <td data-value=${!!s["has-cross-site-ancestor"]}></td>
                  <td data-value=${E(s.priorityValue)}>${s.priority}</td>
                  ${n.schemeBindingEnabled?k`
                    <td title=${l(r.sourceSchemeTooltip)}>${s["source-scheme"]}</td>`:""}
                  ${n.portBindingEnabled?k`
                    <td title=${l(r.sourcePortTooltip)}>${s["source-port"]}</td>`:""}
                </tr>`})}
                ${n.editable?k`<tr placeholder><tr>`:""}
              </table>
            </devtools-data-grid>`,v,{host:v})}),this.registerRequiredCSS(I),this.element.classList.add("cookies-table"),this.#i=a,this.#o=i,this.#e=u,this.#a=!!a;let{devToolsEnableOriginBoundCookies:h}=f.Runtime.hostConfig;this.schemeBindingEnabled=!!h?.schemeBindingEnabled,this.portBindingEnabled=!!h?.portBindingEnabled,this.view=d,this.renderInline=!!o,this.#n=C,this.lastEditedColumnId=null,this.data=[],this.#s="",this.cookieToBlockedReasons=null,this.cookieToExemptionReason=null,this.requestUpdate()}set cookiesData(e){this.setCookies(e.cookies,e.cookieToBlockedReasons,e.cookieToExemptionReason)}set saveCallback(e){this.#i=e}set refreshCallback(e){this.#o=e}set selectedCallback(e){this.#n=e}set aiButtonIsEnabled(e){this.#t=e}get aiButtonIsEnabled(){return this.#t}set onAiButtonClick(e){this.#r=e}set onPopulateAiContextMenu(e){this.#l=e}set aiButtonTitle(e){this.#d=e}set deleteCallback(e){this.#e=e}set editable(e){this.#a=e}set inline(e){this.renderInline=e,this.requestUpdate()}setCookies(e,o,a){this.cookieToBlockedReasons=o||null,this.cookieToExemptionReason=a||null,this.cookies=e;let i=this.data.find(u=>u.key===this.selectedKey),C=this.cookies.find(u=>u.key()===this.selectedKey);this.data=e.sort((u,d)=>u.name().localeCompare(d.name())).map(this.createCookieData.bind(this)),i&&this.lastEditedColumnId&&!C&&(i.inactive=!0,this.data.push(i)),this.requestUpdate()}set cookieDomain(e){this.#s=e}selectedCookie(){return this.cookies.find(e=>e.key()===this.selectedKey)||null}willHide(){super.willHide(),this.lastEditedColumnId=null}performUpdate(){let e=this.#r,o={data:this.data,selectedKey:this.selectedKey,editable:this.#a,deletable:!!this.#e,renderInline:this.renderInline,schemeBindingEnabled:this.schemeBindingEnabled,portBindingEnabled:this.portBindingEnabled,onEdit:this.onUpdateCookie.bind(this),onCreate:this.onCreateCookie.bind(this),onRefresh:this.refresh.bind(this),onDelete:this.onDeleteCookie.bind(this),onSelect:this.onSelect.bind(this),onContextMenu:this.populateContextMenu.bind(this),showAiButton:this.#t,aiButtonTitle:this.#t?this.#d:void 0,onAiButtonClick:this.#t&&e?(i,C)=>{C.stopPropagation();let u=this.cookies.find(d=>d.key()===i.key);u&&e(u,C)}:void 0},a={};this.view(o,a,this.element)}onSelect(e){this.selectedKey=e,this.#n?.(this.selectedCookie())}onDeleteCookie(e){let o=this.cookies.find(a=>a.key()===e.key);o&&this.#e&&this.#e(o,()=>this.refresh())}onUpdateCookie(e,o,a,i){let C=this.cookies.find(d=>d.key()===e.key);if(!C)return;let u={...e,[o]:i};if(!this.isValidCookieData(u)){u.dirty=!0,this.requestUpdate();return}this.lastEditedColumnId=o,this.saveCookie(u,C)}onCreateCookie(e){this.setDefaults(e),this.isValidCookieData(e)?this.saveCookie(e):(e.dirty=!0,this.requestUpdate())}setDefaults(e){e[t.Cookie.Attribute.NAME]===void 0&&(e[t.Cookie.Attribute.NAME]=""),e[t.Cookie.Attribute.VALUE]===void 0&&(e[t.Cookie.Attribute.VALUE]=""),e[t.Cookie.Attribute.DOMAIN]===void 0&&(e[t.Cookie.Attribute.DOMAIN]=this.#s),e[t.Cookie.Attribute.PATH]===void 0&&(e[t.Cookie.Attribute.PATH]="/"),e[t.Cookie.Attribute.EXPIRES]===void 0&&(e[t.Cookie.Attribute.EXPIRES]=g()),e[t.Cookie.Attribute.PARTITION_KEY]===void 0&&(e[t.Cookie.Attribute.PARTITION_KEY]="")}saveCookie(e,o){if(!this.#i)return;let a=this.createCookieFromData(e);this.#i(a,o??null).then(i=>{i||(e.dirty=!0),this.refresh()})}createCookieFromData(e){let o=new t.Cookie.Cookie(e[t.Cookie.Attribute.NAME]||"",e[t.Cookie.Attribute.VALUE]||"",null,e[t.Cookie.Attribute.PRIORITY]);for(let a of[t.Cookie.Attribute.DOMAIN,t.Cookie.Attribute.PATH,t.Cookie.Attribute.HTTP_ONLY,t.Cookie.Attribute.SECURE,t.Cookie.Attribute.SAME_SITE,t.Cookie.Attribute.SOURCE_SCHEME])if(a in e){let i=e[a];$(a)?i===!0&&o.addAttribute(a):o.addAttribute(a,i)}return e.expires&&e.expires!==g()&&o.addAttribute(t.Cookie.Attribute.EXPIRES,new Date(e[t.Cookie.Attribute.EXPIRES]).toUTCString()),t.Cookie.Attribute.SOURCE_PORT in e&&o.addAttribute(t.Cookie.Attribute.SOURCE_PORT,Number.parseInt(e[t.Cookie.Attribute.SOURCE_PORT]||"",10)||void 0),e[t.Cookie.Attribute.PARTITION_KEY_SITE]&&o.setPartitionKey(e[t.Cookie.Attribute.PARTITION_KEY_SITE],e[t.Cookie.Attribute.HAS_CROSS_SITE_ANCESTOR]===!0),o.setSize(e[t.Cookie.Attribute.NAME].length+e[t.Cookie.Attribute.VALUE].length),o}createCookieData(e){let a=e.type()===t.Cookie.Type.REQUEST,i={name:e.name(),value:e.value()};for(let d of[t.Cookie.Attribute.HTTP_ONLY,t.Cookie.Attribute.SECURE,t.Cookie.Attribute.SAME_SITE,t.Cookie.Attribute.SOURCE_SCHEME,t.Cookie.Attribute.SOURCE_PORT])e.hasAttribute(d)&&($(d)?i[d]=!0:i[d]=String(e.getAttribute(d)??!0));i[t.Cookie.Attribute.DOMAIN]=e.domain()||(a?l(r.na):""),i[t.Cookie.Attribute.PATH]=e.path()||(a?l(r.na):""),i[t.Cookie.Attribute.EXPIRES]=e.maxAge()?m.TimeUtilities.secondsToString(Math.floor(e.maxAge())):e.expires()<0?g():e.expires()>864e13?l(r.timeAfter,{date:new Date(864e13).toISOString()}):e.expires()>0?new Date(e.expires()).toISOString():a?l(r.na):g(),e.expires()>864e13&&(i.expiresTooltip=l(r.timeAfterTooltip,{seconds:e.expires(),date:new Date(864e13).toISOString()})),i[t.Cookie.Attribute.PARTITION_KEY_SITE]=e.partitionKeyOpaque()?l(r.opaquePartitionKey).toString():e.topLevelSite(),i[t.Cookie.Attribute.HAS_CROSS_SITE_ANCESTOR]=e.hasCrossSiteAncestor(),i[t.Cookie.Attribute.SIZE]=String(e.size()),i[t.Cookie.Attribute.PRIORITY]=e.priority(),i.priorityValue=["Low","Medium","High"].indexOf(e.priority());let C=this.cookieToBlockedReasons?.get(e)||[];for(let d of C){i.flagged=!0;let h=d.attribute||t.Cookie.Attribute.NAME;i.icons=i.icons||{},h in i.icons?i.icons[h]&&(i.icons[h].title+=`
`+d.uiString):(i.icons[h]=new R,i.icons[h].name="info",i.icons[h].classList.add("small"),i.icons[h].title=d.uiString)}let u=this.cookieToExemptionReason?.get(e)?.uiString;return u&&(i.icons=i.icons||{},i.flagged=!0,i.icons.name=new R,i.icons.name.name="info",i.icons.name.classList.add("small"),i.icons.name.title=u),i.key=e.key(),i}isValidCookieData(e){return(!!e.name||!!e.value)&&this.isValidDomain(e.domain)&&this.isValidPath(e.path)&&this.isValidDate(e.expires)&&this.isValidPartitionKey(e[t.Cookie.Attribute.PARTITION_KEY_SITE])}isValidDomain(e){if(!e)return!0;let o=S.ParsedURL.ParsedURL.fromString("http://"+e);return o!==null&&o.domain()===e}isValidPath(e){if(!e)return!0;let o=S.ParsedURL.ParsedURL.fromString("http://example.com"+e);return o!==null&&o.path===e}isValidDate(e){return!e||e===g()||!isNaN(Date.parse(e))}isValidPartitionKey(e){return e?S.ParsedURL.ParsedURL.fromString(e)!==null:!0}refresh(){this.#o&&this.#o()}populateContextMenu(e,o){let a=this.cookies.find(C=>C.key()===e.key);if(!a)return;let i=a;this.#l?.(i,o),o.revealSection().appendItem(l(r.showRequestsWithThisCookie),()=>{let C=A.UIFilter.UIRequestFilter.filters([{filterType:A.UIFilter.FilterType.CookieDomain,filterValue:i.domain()},{filterType:A.UIFilter.FilterType.CookieName,filterValue:i.name()}]);S.Revealer.reveal(C)},{jslogContext:"show-requests-with-this-cookie"}),c.RelatedIssue.hasIssues(i,c.IssuesManager.IssuesManager.instance())&&o.revealSection().appendItem(l(r.showIssueAssociatedWithThis),()=>{c.RelatedIssue.reveal(i,c.IssuesManager.IssuesManager.instance())},{jslogContext:"show-issue-associated-with-this"})}};export{B as CookiesTable};
//# sourceMappingURL=cookie_table.js.map
