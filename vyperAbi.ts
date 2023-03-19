import { glob } from 'typechain';
import path from 'path';
import fse from 'fs-extra';

type abiExtend = {
  name: string;
  inputs: {
    name: string;
    type: string;
    indexed: boolean;
  }[];
  anonymous: boolean;
  type: string;
  stateMutability?: undefined;
  outputs?: undefined;
  gas?: undefined;
};

const ARTIFACTS_PATH = path.join(__dirname, 'artifacts', 'contracts');
const ABIS_PATH = path.join(__dirname, 'export', 'abi');

// eslint-disable-next-line @typescript-eslint/explicit-module-boundary-types
export async function main() {
  console.log('Removing gas estimation in abis');

  const cwd = process.cwd();
  const allFilesArtifacts = glob(cwd, [`${ARTIFACTS_PATH}/!(build-info)/**.vy/+([a-zA-Z0-9_]).json`]);
  const allFilesAbis = glob(cwd, [`${ABIS_PATH}/**.json`]);

  if ((!allFilesArtifacts || allFilesArtifacts.length === 0) && (!allFilesAbis || allFilesAbis.length === 0)) return;

  for (let i = 0; i < allFilesArtifacts.length; i++) {
    const JSONprop = JSON.parse((await fse.readFile(allFilesArtifacts[i])).toString());
    let abi: abiExtend[] = JSONprop.abi;
    abi = abi.map(obj => {
      delete obj.gas;
      return obj;
    });
    JSONprop.abi = abi;
    await fse.writeFile(allFilesArtifacts[i], JSON.stringify(JSONprop));
  }
  for (let i = 0; i < allFilesAbis.length; i++) {
    const JSONprop: abiExtend[] = JSON.parse((await fse.readFile(allFilesAbis[i])).toString());
    JSONprop.map(obj => {
      delete obj.gas;
      return obj;
    });
    await fse.writeFile(allFilesAbis[i], JSON.stringify(JSONprop));
  }
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
