const { ethers } = require("hardhat");

function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms))
}

async function main() {
  /*
  const swapV2 = await ethers.deployContract("SwapV2");
  await swapV2.waitForDeployment();
  console.log(`SwapV2 deployed to: ${swapV2.target}`);

  await sleep(3000)
  */
  
  const swapV3 = await ethers.deployContract("SwapV3");
  await swapV3.waitForDeployment();
  console.log(`SwapV2 deployed to: ${swapV3.target}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
