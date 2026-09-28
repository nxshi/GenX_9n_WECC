import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const root = path.resolve(import.meta.dirname, "..");
const sourceText = await fs.readFile(path.join(root, "dist/data/results-data.js"), "utf8");
const data = JSON.parse(sourceText.replace(/^window\.RESULTS_DATA\s*=\s*/, "").replace(/;\s*$/, ""));
const outputDir = path.join(root, "dist/downloads");
await fs.mkdir(outputDir, { recursive: true });

const fileNames = { epri:"epri-results.xlsx", kmeans_myopic:"genx-kmeans-myopic-results.xlsx", sampled_myopic:"genx-sampled-weeks-myopic-results.xlsx" };
const font = "Arial", navy = "#17365D", blue = "#D9EAF7";

function styleSheet(sheet, title, headers, rowCount, numberColumns = []) {
  sheet.showGridLines = false;
  sheet.getRange("A2").values = [[title]];
  sheet.getRange("A2").format.font = { name:font, size:14, bold:true, color:navy };
  sheet.getRangeByIndexes(3,0,1,headers.length).values = [headers];
  sheet.getRangeByIndexes(3,0,1,headers.length).format = { fill:navy, font:{name:font,size:10,bold:true,color:"#FFFFFF"}, horizontalAlignment:"center", verticalAlignment:"center", wrapText:true };
  if (rowCount) {
    const body=sheet.getRangeByIndexes(4,0,rowCount,headers.length);
    body.format.font={name:font,size:10,color:"#1F2937"}; body.format.verticalAlignment="center";
    numberColumns.forEach(index=>sheet.getRangeByIndexes(4,index,rowCount,1).format.numberFormat="#,##0.000");
    body.format.borders={preset:"inside",style:"thin",color:"#D9E1EA"};
  }
  sheet.freezePanes.freezeRows(4);
  const used=sheet.getUsedRange(); used.format.autofitColumns(); used.format.autofitRows();
  for(let col=0;col<headers.length;col++){const range=sheet.getRangeByIndexes(0,col,Math.max(rowCount+4,5),1);if(range.format.columnWidth>24)range.format.columnWidth=24;}
}
function addTab(workbook,name,title,headers,rows,numberColumns){const sheet=workbook.worksheets.add(name);if(rows.length)sheet.getRangeByIndexes(4,0,rows.length,headers.length).values=rows;styleSheet(sheet,title,headers,rows.length,numberColumns);return sheet;}

for (const scenario of data.scenarios) {
  const workbook=Workbook.create();
  const summary=addTab(workbook,"Summary",`${scenario.label} results`,["Model year","System cost ($M, 2025 dollars)","CO2 emissions (Mt)"],scenario.years.map(row=>[row.year,row.cost_total,row.emissions_total]),[1,2]);
  summary.getRange("A10").values=[["Workbook contents"]]; summary.getRange("A10").format.font={name:font,size:11,bold:true,color:navy};
  summary.getRange("A11:B17").values=[["Costs","Annual system cost by component"],["Capacity","Total installed capacity by technology"],["Buildout","Cumulative additions minus retirements by technology"],["Generation","Annual generation by technology"],["Emissions","Annual CO2 emissions by region"],["Profiles","Hourly generation and demand by representative week"],["Storage sign","Positive values are discharge; negative values are charge"]];
  summary.getRange("A11:B17").format.font={name:font,size:10,color:"#1F2937"}; summary.getRange("A11:A17").format.fill=blue; summary.getRange("A11:B17").format.autofitColumns(); summary.tabColor=navy;

  const costHeaders=["Model year","Reported total ($M, 2025 dollars)",...data.cost_components.map(x=>`${x} ($M, 2025 dollars)`)];
  addTab(workbook,"Costs",`${scenario.label} system cost`,costHeaders,scenario.years.map(row=>[row.year,row.cost_total,...data.cost_components.map(key=>row.cost_breakdown[key]??0)]),costHeaders.map((_,i)=>i).slice(1));
  const techHeaders=["Model year",...data.technologies.map(x=>`${x} (GW)`)];
  addTab(workbook,"Capacity",`${scenario.label} total installed capacity`,techHeaders,scenario.years.map(row=>[row.year,...data.technologies.map(key=>row.installed_capacity[key]??0)]),techHeaders.map((_,i)=>i).slice(1));
  addTab(workbook,"Buildout",`${scenario.label} cumulative buildout`,techHeaders,scenario.years.map(row=>[row.year,...data.technologies.map(key=>row.capacity_mix[key]??0)]),techHeaders.map((_,i)=>i).slice(1));
  const genHeaders=["Model year",...data.technologies.map(x=>`${x} (TWh)`)];
  addTab(workbook,"Generation",`${scenario.label} annual generation`,genHeaders,scenario.years.map(row=>[row.year,...data.technologies.map(key=>row.generation_mix[key]??0)]),genHeaders.map((_,i)=>i).slice(1));
  const regions=[...new Set(scenario.years.flatMap(row=>Object.keys(row.emissions_breakdown||{})))], emissionHeaders=["Model year","Total (Mt CO2)",...regions.map(x=>`${x} (Mt CO2)`)];
  addTab(workbook,"Emissions",`${scenario.label} annual CO2 emissions`,emissionHeaders,scenario.years.map(row=>[row.year,row.emissions_total,...regions.map(key=>row.emissions_breakdown[key]??0)]),emissionHeaders.map((_,i)=>i).slice(1));
  const profileHeaders=["Model year","Representative week index","Source week","Hour","Demand (GW)",...data.technologies.map(x=>`${x} (GW)`)], profileRows=[];
  for(const yearRow of scenario.years)for(const profile of yearRow.profiles||[]){const week=scenario.weeks.find(item=>item.index===profile.week);for(const point of profile.points||[])profileRows.push([yearRow.year,profile.week,week?.source_week??profile.week,point.hour,point.demand,...data.technologies.map(key=>point.generation[key]??0)]);}
  addTab(workbook,"Profiles",`${scenario.label} representative-week generation profiles`,profileHeaders,profileRows,profileHeaders.map((_,i)=>i).slice(4));
  workbook.recalculate();
  console.log((await workbook.inspect({kind:"table",range:"Summary!A2:C9",include:"values,formulas",tableMaxRows:10,tableMaxCols:5})).ndjson);
  console.log((await workbook.inspect({kind:"match",sheetId:"Summary",range:"A1:C17",searchTerm:"#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A|#NUM!|#NULL!|#SPILL!|#CALC!",options:{useRegex:true,maxResults:50},summary:`${scenario.id} error scan`})).ndjson);
  const preview=await workbook.render({sheetName:"Summary",range:"A1:C17",scale:1.5,format:"png"}); await fs.writeFile(path.join("/private/tmp",`${scenario.id}-download-preview.png`),new Uint8Array(await preview.arrayBuffer()));
  const xlsx=await SpreadsheetFile.exportXlsx(workbook); await xlsx.save(path.join(outputDir,fileNames[scenario.id]));
}
for (const name of await fs.readdir(outputDir)) if (name.endsWith(".inspect.ndjson")) await fs.unlink(path.join(outputDir,name));
