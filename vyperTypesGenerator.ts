import { runTypeChain, glob } from 'typechain';
import path from 'path';
import fse from 'fs-extra';
import util from 'util';
import { exec as childExec } from 'child_process';

const exec = util.promisify(childExec);

const ARTIFACTS_PATH = path.join(__dirname, 'artifacts', 'contracts');
const VYPER_TYPES_TEMP_DIR = 'vyperTypesTemp';
const TYPECHAIN_DIR = 'typechain';

// eslint-disable-next-line @typescript-eslint/explicit-module-boundary-types
export async function generateVyperTypes() {
  console.log('Generating typings for Vyper');

  const cwd = process.cwd();
  const allFiles = glob(cwd, [`${ARTIFACTS_PATH}/!(build-info)/**.vy/+([a-zA-Z0-9_]).json`]);

  if (!allFiles || allFiles.length === 0) return;

  await runTypeChain({
    cwd,
    filesToProcess: allFiles,
    allFiles,
    outDir: VYPER_TYPES_TEMP_DIR,
    target: 'ethers-v5',
  });

  await exec(
    `mv ${VYPER_TYPES_TEMP_DIR}/index.ts ${VYPER_TYPES_TEMP_DIR}/index; mv ${VYPER_TYPES_TEMP_DIR}/*.ts ${TYPECHAIN_DIR}`,
  );
  await exec(`mv ${VYPER_TYPES_TEMP_DIR}/factories/* ${TYPECHAIN_DIR}/factories`);

  const typechainIndexFile = (await fse.readFile(`${TYPECHAIN_DIR}/index.ts`)).toString();
  const vyperIndexFile = (await fse.readFile(`${VYPER_TYPES_TEMP_DIR}/index`)).toString();
  const indexStartCurve = typechainIndexFile.indexOf('/* start curve */');
  let indexFile = typechainIndexFile;
  if (indexStartCurve >= 0) {
    indexFile = typechainIndexFile.substr(0, indexStartCurve);
  }
  indexFile += '/* start curve */\n';
  indexFile += vyperIndexFile;
  await fse.writeFile(`${TYPECHAIN_DIR}/index.ts`, indexFile);

  await fse.remove(path.join(__dirname, VYPER_TYPES_TEMP_DIR));
}
