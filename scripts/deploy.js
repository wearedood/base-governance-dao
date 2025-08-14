const { ethers, upgrades } = require('hardhat');
const { verify } = require('@nomicfoundation/hardhat-verify/verify');

async function main() {
  console.log('Deploying Base Governance DAO...');
  
  // Get the contract factory
  const BaseGovernanceDAO = await ethers.getContractFactory('BaseGovernanceDAO');
  
  // Deploy the contract
  console.log('Deploying contract...');
  const governanceDAO = await BaseGovernanceDAO.deploy();
  
  await governanceDAO.waitForDeployment();
  
  const contractAddress = await governanceDAO.getAddress();
  console.log('BaseGovernanceDAO deployed to:', contractAddress);
  
  // Wait for a few block confirmations
  console.log('Waiting for block confirmations...');
  await governanceDAO.deploymentTransaction().wait(5);
  
  // Verify the contract on Basescan
  if (process.env.BASESCAN_API_KEY) {
    console.log('Verifying contract on Basescan...');
    try {
      await verify(contractAddress, []);
      console.log('Contract verified successfully');
    } catch (error) {
      console.log('Verification failed:', error.message);
    }
  }
  
  // Save deployment info
  const deploymentInfo = {
    contractAddress,
    network: network.name,
    deployer: (await ethers.getSigners())[0].address,
    timestamp: new Date().toISOString(),
    blockNumber: await ethers.provider.getBlockNumber(),
  };
  
  console.log('Deployment completed:', deploymentInfo);
  
  return deploymentInfo;
}

// Execute deployment
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Deployment failed:', error);
    process.exit(1);
  });
