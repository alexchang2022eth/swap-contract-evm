// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// You can also run a script with `npx hardhat run <script>`. If you do that, Hardhat
// will compile your contracts, add the Hardhat Runtime Environment's members to the
// global scope, and execute the script.
require('@openzeppelin/hardhat-upgrades');
const { ethers, upgrades, hardhatArguments } = require("hardhat");

let WETH
let swapV2
let swapV3

const network = hardhatArguments.network;
if(network === 'eth_main')
{
  WETH = '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2'
  swapV2 = ''
  swapV3 = ''
} else if (network === 'sepolia') {
  WETH = '0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9'
  //WETH = '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14'
  swapV2 = ''
  swapV3 = ''
} 

async function main() {
  const SwapX = await ethers.getContractFactory("SwapX");
  const swapx = await upgrades.deployProxy(SwapX, [swapV2, swapV3], {unsafeAllow: ['delegatecall']});
  await swapx.waitForDeployment();

  console.table({
    "SwapX Proxy address": await swapx.getAddress()
  });
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
