const BNumber = require('bignumber.js');
const {ethers, upgrades} = require("hardhat");
const cnf = require('./cnf')

const StratAlpacaInit = {
    "poolId": 3,
    "fairLaunchAddress": '0xA625AB01B08ce023B2a342Dbb12a16f2C8489A8F',
    "alpacaToken": "0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F",
    "alpacaVault":'0x7C9e73d4C71dae564d41F78d56439bB4ba87592f',
}

async function main() {
    const [owner] = await ethers.getSigners();
    console.log("owner address=", owner.address);

    const AlBUSD = await ethers.getContractFactory("AlToken");
    // const alBUSD = await AlBUSD.deploy();
    const alBUSD = await AlBUSD.attach("0xA80f25C3F8cCF3bB31660C356f8A2b7335c7daC5");
    console.log("AlBUSD: ", alBUSD.address)
    // await wait(20000);

    const Alchemist = await ethers.getContractFactory("Alchemist");
    // const saxophone = await Saxophone.deploy(
    //     cnf.busd,
    //     alBUSD.address,
    //     cnf.governance,
    //     cnf.sentinel
    // );
    const alchemist = await Alchemist.attach("0xE7EF103b4b055C4b707780Df7DeA35ccEd9B49DF")
    console.log("Alchemist: ", alchemist.address)
    // await wait(20000);

    const TransmuterB = await ethers.getContractFactory("TransmuterB");
    // const transmuterB = await TransmuterB.deploy(
    //     alBUSD.address,
    //     cnf.busd,
    //     cnf.governance
    // );

    const transmuterB = await TransmuterB.attach("0xF71a95c9A99d79BEb2B34B94072a88dA73520B52");
    console.log("TransmuterB: ", transmuterB.address)
    // await wait(20000);

    const StratAlpaca = await ethers.getContractFactory("StratAlpaca");
    // const stratAlpaca = await upgrades.deployProxy(StratAlpaca,[
    //     StratAlpacaInit.poolId,
    //     StratAlpacaInit.fairLaunchAddress,
    //     StratAlpacaInit.alpacaToken,
    //     StratAlpacaInit.alpacaVault,
    //     cnf.busd,
    //     cnf.wbnb,
    //     cnf.pancakeRouter,
    //     cnf.Zero,
    //     false
    // ], { initializer: 'initialize', unsafeAllow: ['delegatecall'] });
    const stratAlpaca = await StratAlpaca.attach("0x43c9430CE65c3C34774e9053AE45FAA25b5011D4")
    console.log("StratAlpaca: ", stratAlpaca.address)
    // await wait(20000);


    const AlpacaSimpleVault = await ethers.getContractFactory("SimpleVault");
    // const alpacaSimpleVault = await upgrades.deployProxy(AlpacaSimpleVault,[
    //     cnf.busd,
    //     stratAlpaca.address,
    //     "alAlpacaBUSD",
    //     "alAlpacaBUSD",
    //     0
    // ], { initializer: 'initialize', unsafeAllow: ['delegatecall'] });

    const alpacaSimpleVault = await AlpacaSimpleVault.attach("0xc7aCCcC6F7FAA9fCF5922A87249dF7571e6A1852")

    // await stratAlpaca.setVault(alpacaSimpleVault.address);
    console.log("AlpacaSimpleVault: ", alpacaSimpleVault.address)
    // await wait(20000);

    const YearnVaultAdapter = await ethers.getContractFactory("YearnVaultAdapter");
    // const yearnVaultAdapter = await YearnVaultAdapter.deploy(
    //     alpacaSimpleVault.address,
    //     alchemist.address
    // );
    const yearnVaultAdapter = await YearnVaultAdapter.attach("0xc733EE2cC70faC441f581de4Dc7A7d58081C7CB0")
    console.log("YearnVaultAdapter: ", yearnVaultAdapter.address)
    // await wait(20000);

    const YearnVaultAdapterWithIndirection = await ethers.getContractFactory("YearnVaultAdapterWithIndirection");
    // const yearnVaultAdapterWithIndirection = await YearnVaultAdapterWithIndirection.deploy(
    //     alpacaSimpleVault.address,
    //     transmuterB.address
    // );
    const yearnVaultAdapterWithIndirection = await YearnVaultAdapterWithIndirection.attach("0x2F99Dbe7949C44cc33E7265C1a1e688D3eF57c8e")
    console.log("YearnVaultAdapterWithIndirection: ", yearnVaultAdapterWithIndirection.address)
    // await wait(20000);

    console.log("参数配置初始化")
    console.log("alchemist 初始化")
    // 注意开局需要吧币放进银行里。flushActiveVault看相应的币弄成多少。
    await alchemist.setTransmuter(transmuterB.address)
    await alchemist.setRewards(cnf.rewards)
    await alchemist.setHarvestFee(cnf.harvestFee)
    await alchemist.setOracleAddress('0xcBb98864Ef56E9042e7d2efef76141f15731B82f', 98000000)
    await alchemist.initialize(yearnVaultAdapter.address)


    console.log("transmuterB 初始化")
    await transmuterB.setRewards(cnf.rewards)
    await transmuterB.setTransmutationPeriod(50)
    await transmuterB.setWhitelist(cnf.TransmuterGov, true)
    await transmuterB.setWhitelist(alchemist.address, true)
    await transmuterB.setKeepers([cnf.TransmuterGov], [true])
    await transmuterB.setPause(false)
    console.log("transmuterB 初始化")
    await transmuterB.initialize(yearnVaultAdapterWithIndirection.address)

    console.log("alpacaSimpleVault 初始化")
    await alpacaSimpleVault.setNeedWhitelist(true)
    await alpacaSimpleVault.whitelist(yearnVaultAdapter.address, true)
    await alpacaSimpleVault.whitelist(yearnVaultAdapterWithIndirection.address, true)

    console.log("alToken 初始化")
    await alBUSD.whitelist(alchemist.address, true)
    await alBUSD.setSentinel(cnf.TransmuterGov)
    await alBUSD.setCeiling(alchemist.address, 10000000001e18)


    console.log("over")
}

function wait(ms) {
    return new Promise(resolve => setTimeout(() => resolve(), ms));
};

// saveJsonFile("abc");
main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });