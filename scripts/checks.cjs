// Same dependency-free checks locally and in GitHub Actions. Discover actual files
// so cache version changes and missing shell glob matches cannot break the runner.
const fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process');
process.chdir(path.resolve(__dirname,'..'));
const mode=process.argv[2];
function run(args){const result=spawnSync(process.execPath,args,{stdio:'inherit'});if(result.error)console.error(result.error);return result.status??1;}
if(mode==='test'){
 const files=fs.readdirSync('tests').filter(name=>/\.test\.(cjs|mjs)$/.test(name)).sort().map(name=>'tests/'+name);
 if(!files.length)throw Error('No regression tests found');
 console.log('Running '+files.length+' regression test files');
 process.exitCode=run(['--test','--test-concurrency=2','--test-timeout=60000',...files]);
}else if(mode==='syntax'){
 const files=[];
 function walk(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){const file=path.join(dir,entry.name);if(entry.isDirectory()){if(entry.name!=='vendor')walk(file);}else if(/\.(js|mjs)$/.test(entry.name))files.push(file);}}
 walk('play');if(!files.length)throw Error('No client source files found');
 let failed=0;for(const file of files.sort())if(run(['--check',file])){console.error('Syntax check failed: '+file);failed++;}
 console.log('Client syntax: '+(files.length-failed)+' / '+files.length+' passed');process.exitCode=failed?1:0;
}else{console.error('Usage: node scripts/checks.cjs <test|syntax>');process.exitCode=1;}
