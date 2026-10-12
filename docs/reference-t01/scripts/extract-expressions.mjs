import {readFileSync,writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const require=createRequire(import.meta.url), ts=require(process.env.T01_TYPESCRIPT_MODULE||'typescript');
const inventory=JSON.parse(readFileSync(resolve(root,'http-inventory.json')));
const result=[];
for(const source of new Set(inventory.map(r=>r.source))){
 const text=readFileSync(resolve(root,'sources',source),'utf8');
 const ast=ts.createSourceFile(source,text,ts.ScriptTarget.Latest,true);
 const item={source,responseExpressions:[],typeDeclarations:[]};
 function walk(n){
  if(ts.isCallExpression(n)&&n.expression.getText(ast)==='NextResponse.json')item.responseExpressions.push({line:ast.getLineAndCharacterOfPosition(n.getStart()).line+1,payload:n.arguments[0]?.getText(ast),options:n.arguments[1]?.getText(ast)||'default 200'});
  if(ts.isTypeAliasDeclaration(n))item.typeDeclarations.push(n.getText(ast));
  ts.forEachChild(n,walk);
 }
 walk(ast);result.push(item);
}
writeFileSync(resolve(root,'response-expressions.json'),JSON.stringify(result,null,2)+'\n');
console.log(`${result.length} source files with exact AST response/type expressions`);
