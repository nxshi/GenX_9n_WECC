(() => {
  const data = window.RESULTS_DATA;
  const charts = {};
  const palette = ["#69a8ff", "#4ee1d1", "#f4ad62", "#f07178", "#a678e2", "#d4b541", "#6bbf9a", "#d58ef0", "#e8b76b"];
  const fmt = (value, digits = 0) => value == null ? "Not provided" : new Intl.NumberFormat("en-US", {maximumFractionDigits: digits}).format(value);
  const sumValues = object => Object.values(object || {}).reduce((total, value) => total + (Number(value) || 0), 0);
  const scenario = id => data.scenarios.find(item => item.id === id);
  const years = item => item.years.map(row => row.year);
  function colors(labels) { return labels.map((label, index) => data.technology_colors[label] || palette[index % palette.length]); }
  function resetChart(id) { if (charts[id]) charts[id].destroy(); }
  function lineChart(id, labels, datasets, opts = {}) { resetChart(id); charts[id] = new Chart(document.getElementById(id), {type:"line",data:{labels,datasets},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:"index",intersect:false},plugins:{legend:{labels:{color:"#c9d5ee",boxWidth:10,font:{size:11}}},tooltip:{callbacks:{title:items=>opts.tooltipTitle&&items.length?`${opts.tooltipTitle} ${items[0].label}`:items[0]?.label,label:c=>`${c.dataset.label}: ${fmt(c.parsed.y,2)} ${opts.unit||""}`}}},scales:{x:{ticks:{color:"#9eacc8"},grid:{color:"rgba(94,121,174,.13)"},title:{display:!!opts.xTitle,text:opts.xTitle,color:"#9eacc8"}},y:{stacked:!!opts.stacked,ticks:{color:"#9eacc8"},grid:{color:"rgba(94,121,174,.13)"},title:{display:!!opts.unit,text:opts.unit,color:"#9eacc8"}}}}}); }
  function barChart(id, labels, datasets, opts = {}) { resetChart(id); charts[id] = new Chart(document.getElementById(id), {type:"bar",data:{labels,datasets:datasets.map(dataset=>({...dataset,borderWidth:0}))},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{labels:{color:"#c9d5ee",boxWidth:10,font:{size:11}}},tooltip:{callbacks:{label:c=>`${c.dataset.label}: ${fmt(c.parsed.y,2)} ${opts.unit||""}`}}},scales:{x:{stacked:!!opts.stacked,ticks:{color:"#9eacc8"},grid:{display:false}},y:{stacked:!!opts.stacked,ticks:{color:"#9eacc8"},grid:{color:"rgba(94,121,174,.13)"},title:{display:!!opts.unit,text:opts.unit,color:"#9eacc8"}}}}}); }
  function populateSelect(select, options, selected) { select.innerHTML = options.map(option => `<option value="${option.value}" ${String(option.value)===String(selected)?"selected":""}>${option.label}</option>`).join(""); }
  function stackDatasets(rows, field, unit) { const active = data.technologies.filter(tech => rows.some(row => (row[field]||{})[tech])); return active.map((tech, index) => ({label:tech,data:rows.map(row => row[field][tech] || 0),backgroundColor:colors([tech])[0],borderColor:colors([tech])[0],borderWidth:1,stack:"total"})); }
  const slugify = value => value.toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-|-$/g,"");
  function downloadBlob(blob, fileName) { const url=URL.createObjectURL(blob); const link=document.createElement("a"); link.href=url; link.download=fileName; document.body.append(link); link.click(); link.remove(); setTimeout(()=>URL.revokeObjectURL(url),1000); }
  function chartFileName(id, extension) { const chartContainer=document.getElementById(id)?.closest(".chart-panel,.card"); const title=chartContainer?.querySelector("h2")?.textContent || id; return `${slugify(title)}.${extension}`; }
  function downloadChartPng(id) { const chart=charts[id]; if(!chart)return; const source=chart.canvas, canvas=document.createElement("canvas"); canvas.width=source.width; canvas.height=source.height; const context=canvas.getContext("2d"); context.fillStyle="#0d1b36"; context.fillRect(0,0,canvas.width,canvas.height); context.drawImage(source,0,0); canvas.toBlob(blob=>blob&&downloadBlob(blob,chartFileName(id,"png")),"image/png"); }
  function downloadChartCsv(id) { const chart=charts[id]; if(!chart)return; const escape=value=>{const text=value==null?"":String(value);return /[",\n]/.test(text)?`"${text.replace(/"/g,'""')}"`:text;}; const axis=id.includes("profile")?"Hour":"Model year"; const headers=[axis,...chart.data.datasets.map(dataset=>dataset.label||"Series")]; const rows=chart.data.labels.map((label,index)=>[label,...chart.data.datasets.map(dataset=>dataset.data[index]??"")]); const csv=[headers,...rows].map(row=>row.map(escape).join(",")).join("\r\n"); downloadBlob(new Blob(["\ufeff",csv],{type:"text/csv;charset=utf-8"}),chartFileName(id,"csv")); }
  function addChartDownloads() { document.querySelectorAll(".card canvas").forEach(canvas=>{ const container=canvas.closest(".chart-panel,.card"); if(container.querySelector(":scope > .chart-downloads"))return; const title=container.querySelector("h2")?.textContent||"chart", controls=document.createElement("div"); controls.className="chart-downloads"; controls.innerHTML=`<span>Download this chart</span><button type="button" data-format="png" aria-label="Download ${title} as PNG">PNG</button><button type="button" data-format="csv" aria-label="Download ${title} data as CSV">CSV</button>`; controls.addEventListener("click",event=>{const button=event.target.closest("button");if(!button)return;button.dataset.format==="png"?downloadChartPng(canvas.id):downloadChartCsv(canvas.id);}); container.append(controls); }); }
  function renderWeeklyProfile(chartId, selected, selectedYearValue, selectedWeekValue) {
    const selectedYear = selected.years.find(row => row.year === Number(selectedYearValue)) || selected.years.at(-1);
    const selectedWeek = Number(selectedWeekValue);
    const profile = (selectedYear.profiles || []).find(row=>row.week===selectedWeek);
    const points = profile ? profile.points : [];
    const technologies = data.technologies.filter(tech=>points.some(point=>point.generation[tech]));
    const profileSets = technologies.map(tech=>({label:tech,data:points.map(point=>point.generation[tech]||0),borderColor:colors([tech])[0],backgroundColor:colors([tech])[0],fill:true,pointRadius:0,borderWidth:1,stack:"generation",tension:.12}));
    if (points.some(point=>point.demand!=null)) profileSets.push({label:"Demand",data:points.map(point=>point.demand),borderColor:"#ffffff",backgroundColor:"transparent",fill:false,pointRadius:0,borderWidth:4,order:-100,stack:"demand",tension:.1});
    lineChart(chartId,points.map(point=>point.hour),profileSets,{stacked:true,unit:"GW",xTitle:"Hours",tooltipTitle:"Hour"});
    return {year:selectedYear.year,week:selected.weeks.find(row=>row.index===selectedWeek)};
  }
  function explorer() {
    const scenarioSelect = document.getElementById("scenario"), yearSelect = document.getElementById("profile-year"), weekSelect = document.getElementById("week");
    const topControls = scenarioSelect.closest(".controls");
    topControls.classList.add("scenario-control-row");
    scenarioSelect.closest(".control").classList.add("scenario-primary");
    const profileCard = document.getElementById("profile").closest(".card");
    document.getElementById("technology-legend")?.remove();
    document.getElementById("profile-note")?.remove();
    const profileControls = document.createElement("div");
    profileControls.className = "controls profile-control-row";
    profileControls.append(yearSelect.closest(".control"), weekSelect.closest(".control"));
    profileCard.insertBefore(profileControls, document.getElementById("profile").closest(".chart-wrap"));
    const costCard = document.getElementById("cost-total").closest(".card");
    const costBreakdownCard = document.getElementById("cost-breakdown").closest(".card");
    costCard.classList.remove("wide");
    costCard.querySelector("h2").textContent = "System Cost";
    costCard.querySelector(".sub").textContent = "Annual cost by component across model years.";
    costBreakdownCard.querySelector("h2").textContent = "Cumulative Buildout";
    costBreakdownCard.querySelector(".sub").textContent = "Cumulative additions minus retirements by technology across model years.";
    const emissionsCard = document.getElementById("emissions-total").closest(".card");
    const emissionsBreakdownCard = document.getElementById("emissions-breakdown").closest(".card");
    emissionsCard.classList.remove("wide");
    emissionsCard.querySelector("h2").textContent = "CO₂ Emissions";
    emissionsCard.querySelector(".sub").textContent = "Annual CO₂ emissions by region across model years.";
    emissionsBreakdownCard.remove();
    const capacityCard = document.getElementById("capacity-mix").closest(".card");
    capacityCard.querySelector("h2").textContent = "Total Installed Capacity";
    capacityCard.querySelector(".sub").textContent = "Installed capacity by technology across model years.";
    const generationCard = document.getElementById("generation-mix").closest(".card");
    generationCard.querySelector("h2").textContent = "Generation Mix";
    generationCard.querySelector(".sub").textContent = "Annual generation by technology across model years.";
    profileCard.querySelector("h2").textContent = "Weekly Generation Profile";
    profileCard.querySelector(".sub").textContent = "Hourly generation by technology with demand.";
    profileCard.classList.remove("wide");
    const addChartNote = (card, text) => {
      const note = document.createElement("p");
      note.className = "note chart-note";
      note.textContent = text;
      card.append(note);
    };
    addChartNote(costCard, data.chart_notes.cost);
    addChartNote(emissionsCard, data.chart_notes.emissions);
    addChartNote(capacityCard, data.chart_notes.installed_capacity);
    addChartNote(costBreakdownCard, data.chart_notes.buildout);
    addChartNote(generationCard, data.chart_notes.generation);
    const chartGrid = profileCard.parentElement;
    chartGrid.append(costCard, emissionsCard, capacityCard, costBreakdownCard, generationCard, profileCard);
    const explorerStyles = document.createElement("style");
    explorerStyles.textContent = `.scenario-control-row{padding:24px}.scenario-primary{min-width:min(100%,360px)}.scenario-primary label{font-size:13px}.scenario-primary select{min-height:54px;font-size:17px;font-weight:700;padding:14px 44px 14px 16px}.profile-control-row{margin:0 0 16px;padding:14px;background:rgba(7,17,38,.45)}.profile-control-row .control{min-width:220px}@media(max-width:560px){.scenario-primary,.profile-control-row .control{min-width:100%}}`;
    document.head.append(explorerStyles);
    populateSelect(scenarioSelect,data.scenarios.map(item=>({value:item.id,label:item.label})),"epri");
    const renderProfile = () => {
      const selected = scenario(scenarioSelect.value);
      renderWeeklyProfile("profile",selected,yearSelect.value,weekSelect.value);
    };
    const renderScenario = () => {
      const selected = scenario(scenarioSelect.value);
      populateSelect(yearSelect, selected.years.map(row=>({value:row.year,label:row.year})), yearSelect.value || 2045);
      populateSelect(weekSelect, selected.weeks.map(row=>({value:row.index,label:row.label})), weekSelect.value || 1);
      document.getElementById("summary")?.remove();
      barChart("cost-total",years(selected),data.cost_components.map((key,index)=>({label:key,data:selected.years.map(row=>row.cost_breakdown[key]||0),backgroundColor:palette[index%palette.length],borderColor:palette[index%palette.length],borderWidth:1,stack:"cost"})),{stacked:true,unit:"$M (2025 dollars)"});
      barChart("capacity-mix",years(selected),stackDatasets(selected.years,"installed_capacity","GW"),{stacked:true,unit:"GW"});
      barChart("cost-breakdown",years(selected),stackDatasets(selected.years,"capacity_mix","GW"),{stacked:true,unit:"GW"});
      barChart("generation-mix",years(selected),stackDatasets(selected.years,"generation_mix","TWh"),{stacked:true,unit:"TWh"});
      const regions = [...new Set(selected.years.flatMap(row=>Object.keys(row.emissions_breakdown || {})))];
      barChart("emissions-total",years(selected),regions.map((region,index)=>({label:region,data:selected.years.map(row=>(row.emissions_breakdown||{})[region]||0),backgroundColor:palette[index%palette.length],borderColor:palette[index%palette.length],borderWidth:1,stack:"emissions"})),{stacked:true,unit:"Mt CO₂"});
      const notes=document.getElementById("method-notes");
      if(data.method_notes.length) notes.innerHTML=data.method_notes.map(note=>`<li>${note}</li>`).join("");
      else notes.closest(".method")?.remove();
      renderProfile();
    };
    scenarioSelect.addEventListener("change",()=>{yearSelect.value="";weekSelect.value="";renderScenario();});
    yearSelect.addEventListener("change",renderProfile);
    weekSelect.addEventListener("change",renderProfile);
    renderScenario();
  }
  function comparison() {
    const checks = document.getElementById("scenario-checks");
    const scenarioASelect = document.getElementById("net-scenario-a");
    const scenarioBSelect = document.getElementById("net-scenario-b");
    const profileYearSelect = document.getElementById("compare-profile-year");
    const profileWeekSelect = document.getElementById("compare-profile-week");
    const stored = JSON.parse(localStorage.getItem("wecc-visible-scenarios") || "null"); let visible = new Set(stored || data.scenarios.map(item=>item.id));
    const scenarioOptions = data.scenarios.map(item=>({value:item.id,label:item.label}));
    populateSelect(scenarioASelect,scenarioOptions,data.scenarios[0]?.id);
    populateSelect(scenarioBSelect,scenarioOptions,data.scenarios.at(-1)?.id);
    populateSelect(profileYearSelect,data.years.map(year=>({value:year,label:year})),data.years.at(-1));
    const weekIndices = [...new Set(data.scenarios.flatMap(item=>item.weeks.map(week=>week.index)))].sort((a,b)=>a-b);
    populateSelect(profileWeekSelect,weekIndices.map(index=>({value:index,label:`Week ${index}`})),weekIndices[0]);
    const rowForYear = (item, year) => item.years.find(row=>row.year===year) || {};
    const netDatasets = (scenarioA, scenarioB, keys, field, colorFor) => keys.map((key,index)=>({
      label:key,
      data:data.years.map(year=>Number((rowForYear(scenarioA,year)[field]||{})[key]||0)-Number((rowForYear(scenarioB,year)[field]||{})[key]||0)),
      backgroundColor:colorFor(key,index),
      stack:"net",
    }));
    const renderAllScenarioCharts = () => {
      const active = data.scenarios.filter(item=>visible.has(item.id));
      const lines = value => active.map(item=>{const index=data.scenarios.indexOf(item);return {label:item.label,data:item.years.map(value),borderColor:palette[index],backgroundColor:palette[index]+"2e",fill:false,tension:.25,pointRadius:4,borderWidth:2.5};});
      lineChart("compare-cost-all",data.years,lines(row=>row.cost_total),{unit:"$M (2025 dollars)"});
      lineChart("compare-emissions-all",data.years,lines(row=>row.emissions_total),{unit:"Mt CO₂"});
      lineChart("compare-buildout-all",data.years,lines(row=>sumValues(row.capacity_mix)),{unit:"GW"});
      lineChart("compare-generation-all",data.years,lines(row=>sumValues(row.generation_mix)),{unit:"TWh"});
    };
    const renderComparisonProfiles = () => {
      const scenarioA = scenario(scenarioASelect.value);
      const scenarioB = scenario(scenarioBSelect.value);
      const profileA = renderWeeklyProfile("compare-profile-a",scenarioA,profileYearSelect.value,profileWeekSelect.value);
      const profileB = renderWeeklyProfile("compare-profile-b",scenarioB,profileYearSelect.value,profileWeekSelect.value);
      document.getElementById("compare-profile-a-title").textContent = `Weekly Generation Profile A: ${scenarioA.label}`;
      document.getElementById("compare-profile-b-title").textContent = `Weekly Generation Profile B: ${scenarioB.label}`;
      document.getElementById("compare-profile-a-sub").textContent = `${profileA.year} · ${profileA.week?.label || `Week ${profileWeekSelect.value}`}. Hourly generation by technology with demand.`;
      document.getElementById("compare-profile-b-sub").textContent = `${profileB.year} · ${profileB.week?.label || `Week ${profileWeekSelect.value}`}. Hourly generation by technology with demand.`;
    };
    const renderPairwiseCharts = () => {
      const scenarioA = scenario(scenarioASelect.value);
      const scenarioB = scenario(scenarioBSelect.value);
      const direction = `${scenarioA.label} − ${scenarioB.label}`;
      document.getElementById("compare-cost-net-title").textContent = `Net System Cost: ${direction}`;
      document.getElementById("compare-emissions-net-title").textContent = `Net CO₂ Emissions: ${direction}`;
      document.getElementById("compare-buildout-net-title").textContent = `Net Cumulative Buildout: ${direction}`;
      document.getElementById("compare-generation-net-title").textContent = `Net Generation Mix: ${direction}`;
      barChart("compare-cost-net",data.years,netDatasets(scenarioA,scenarioB,data.cost_components,"cost_breakdown",(key,index)=>palette[index%palette.length]),{stacked:true,unit:"$M (2025 dollars)"});
      const regions = [...new Set([...scenarioA.years,...scenarioB.years].flatMap(row=>Object.keys(row.emissions_breakdown||{})))];
      barChart("compare-emissions-net",data.years,netDatasets(scenarioA,scenarioB,regions,"emissions_breakdown",(key,index)=>palette[index%palette.length]),{stacked:true,unit:"Mt CO₂"});
      barChart("compare-buildout-net",data.years,netDatasets(scenarioA,scenarioB,data.technologies,"capacity_mix",key=>data.technology_colors[key]),{stacked:true,unit:"GW"});
      barChart("compare-generation-net",data.years,netDatasets(scenarioA,scenarioB,data.technologies,"generation_mix",key=>data.technology_colors[key]),{stacked:true,unit:"TWh"});
      renderComparisonProfiles();
    };
    checks.innerHTML = data.scenarios.map(item=>`<label class="scenario-check"><input type="checkbox" value="${item.id}" ${visible.has(item.id)?"checked":""}><span>${item.label}</span></label>`).join("");
    checks.querySelectorAll("input").forEach(input=>input.addEventListener("change",()=>{
      if(input.checked) visible.add(input.value);
      else if(visible.size===1&&visible.has(input.value)) input.checked=true;
      else visible.delete(input.value);
      localStorage.setItem("wecc-visible-scenarios",JSON.stringify([...visible]));
      renderAllScenarioCharts();
    }));
    const keepDistinct = changed => {
      if (scenarioASelect.value===scenarioBSelect.value) {
        const replacement=data.scenarios.find(item=>item.id!==changed.value);
        (changed===scenarioASelect?scenarioBSelect:scenarioASelect).value=replacement.id;
      }
      renderPairwiseCharts();
    };
    scenarioASelect.addEventListener("change",()=>keepDistinct(scenarioASelect));
    scenarioBSelect.addEventListener("change",()=>keepDistinct(scenarioBSelect));
    profileYearSelect.addEventListener("change",renderComparisonProfiles);
    profileWeekSelect.addEventListener("change",renderComparisonProfiles);
    const notes=document.getElementById("method-notes");
    if(data.method_notes.length) notes.innerHTML=data.method_notes.map(note=>`<li>${note}</li>`).join("");
    else notes.closest(".method")?.remove();
    renderAllScenarioCharts();
    renderPairwiseCharts();
  }
  document.addEventListener("DOMContentLoaded",()=>{
    const notesHeading = document.querySelector(".method h2");
    if (notesHeading) notesHeading.textContent = "Notes";
    document.body.dataset.page==="compare"?comparison():explorer();
    addChartDownloads();
  });
})();
