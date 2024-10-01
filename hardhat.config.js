require("@nomicfoundation/hardhat-toolbox");
require('hardhat-contract-sizer');

const PRIVATE_KEY = process.env.PRIV_KEY;
/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.27",
        settings: {
          optimizer: {
            enabled: true,
            runs: 100
          },
          viaIR: true
        }
      }
    ]
  },
  sourcify: {
    enabled: false 
  },
  networks: {
    sepolia: {
      url: `https://sepolia.infura.io/v3/31e12e01809b4fc5accd1646be44fa83`,
      gasPrice: 330000000000,  // 3Gwei
      chainId: 11155111,
      accounts: [`0x${PRIVATE_KEY}`]
    },
    eth_main: {
      url: 'https://nd-252-188-851.p2pify.com/a2f5933f76b31371b058f59a84894bd8',
      gasPrice: 13000000000,
      chainId: 1,
      accounts: [`0x${PRIVATE_KEY}`]
    }
  },
  etherscan: {
    apiKey: {
      mainnet: 'RJ28XMY1VJHSV21R2SNMQFMXWNDXHXS3UC',
      sepolia:'RJ28XMY1VJHSV21R2SNMQFMXWNDXHXS3UC',
    },
  },
  contractSizer: {
    alphaSort: true,
    runOnCompile: true,
    disambiguatePaths: false
  }
};
