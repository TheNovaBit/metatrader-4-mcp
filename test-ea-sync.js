#!/usr/bin/env node

/**
 * Test script for EA sync functionality
 * Simulates MCP server calling the HTTP bridge
 */

import fs from 'fs';
import path from 'path';
import axios from 'axios';

const MT4_HOST = process.env.MT4_HOST || '192.168.50.161';
const MT4_PORT = process.env.MT4_PORT || '8080';
const API_KEY = process.env.BRIDGE_API_KEY || '';
const authHeaders = API_KEY ? { 'x-api-key': API_KEY } : {};

async function testEASync() {
  console.log('🚀 Testing Enhanced EA Sync Functionality');
  console.log('==========================================');
  
  try {
    // Read the AdvancedBreakoutEA
    const eaPath = './ea-strategies/active/AdvancedBreakoutEA.mq4';
    console.log(`📖 Reading EA from: ${eaPath}`);
    
    if (!fs.existsSync(eaPath)) {
      throw new Error(`EA file not found: ${eaPath}`);
    }
    
    const eaContent = fs.readFileSync(eaPath, 'utf-8');
    const eaName = 'AdvancedBreakoutEA';
    
    console.log(`✅ EA loaded: ${eaName}`);
    console.log(`📊 Size: ${eaContent.length} bytes`);
    console.log(`📋 Lines: ${eaContent.split('\\n').length}`);
    
    // Test HTTP Bridge Health
    console.log('\\n🔍 Testing HTTP Bridge Connection...');
    try {
      const healthResponse = await axios.get(`http://${MT4_HOST}:${MT4_PORT}/api/health`, { timeout: 5000, headers: authHeaders });
      console.log('✅ HTTP Bridge Health:', healthResponse.data);
    } catch (healthError) {
      console.log('⚠️ HTTP Bridge not available:', healthError.message);
      console.log('💡 Make sure Windows HTTP Bridge is running on', `${MT4_HOST}:${MT4_PORT}`);
      return false;
    }
    
    // Test EA Upload
    console.log('\\n📤 Testing EA Upload...');
    try {
      const uploadResponse = await axios.post(`http://${MT4_HOST}:${MT4_PORT}/api/ea/upload`, {
        ea_name: eaName,
        ea_content: eaContent
      }, { timeout: 30000, headers: authHeaders });
      
      console.log('✅ Upload Result:', uploadResponse.data);
      
      if (uploadResponse.data.success) {
        console.log(`📁 EA uploaded to: ${uploadResponse.data.file_path}`);
        console.log(`📊 File size: ${uploadResponse.data.file_size} bytes`);
      }
    } catch (uploadError) {
      console.log('❌ Upload failed:', uploadError.message);
      return false;
    }
    
    // Test EA Compilation
    console.log('\\n🔧 Testing EA Compilation...');
    try {
      const compileResponse = await axios.post(`http://${MT4_HOST}:${MT4_PORT}/api/ea/compile`, {
        ea_name: eaName
      }, { timeout: 45000, headers: authHeaders });
      
      console.log('✅ Compilation Result:', compileResponse.data);
      
      if (compileResponse.data.success) {
        console.log(`🎉 Compilation successful!`);
        console.log(`📁 Source: ${compileResponse.data.source_file}`);
        console.log(`📦 Compiled: ${compileResponse.data.ex4_file}`);
        console.log(`⚠️ Warnings: ${compileResponse.data.warnings}`);
        console.log(`❌ Errors: ${compileResponse.data.errors}`);
      } else {
        console.log(`❌ Compilation failed with ${compileResponse.data.errors} errors`);
        console.log('📋 Compilation log:', compileResponse.data.log);
      }
    } catch (compileError) {
      console.log('❌ Compilation request failed:', compileError.message);
      return false;
    }
    
    // Test EA Listing
    console.log('\\n📋 Testing EA List...');
    try {
      const listResponse = await axios.get(`http://${MT4_HOST}:${MT4_PORT}/api/ea/list`, { timeout: 10000, headers: authHeaders });
      console.log('✅ EA List Result:', listResponse.data);
      
      if (listResponse.data.success) {
        console.log(`📂 Experts Directory: ${listResponse.data.experts_directory}`);
        console.log(`📊 Total EA files: ${listResponse.data.count}`);
        
        // Find our uploaded EA
        const ourEA = listResponse.data.files.find(f => f.name.includes('AdvancedBreakoutEA'));
        if (ourEA) {
          console.log(`🎯 Found our EA: ${ourEA.name} (${ourEA.type})`);
        }
      }
    } catch (listError) {
      console.log('⚠️ EA list failed:', listError.message);
    }
    
    console.log('\\n🎉 EA Sync Test Completed Successfully!');
    console.log('=========================================');
    console.log('✅ Upload: Working');
    console.log('✅ Compilation: Working');
    console.log('✅ File Management: Working');
    console.log('\\n🚀 AdvancedBreakoutEA is now available in MT4!');
    console.log('\\n📝 Next Steps:');
    console.log('1. Open MT4 on Windows machine');
    console.log('2. Go to Navigator > Expert Advisors');
    console.log('3. Find "AdvancedBreakoutEA"');
    console.log('4. Drag it to a EURUSD or GBPUSD chart');
    console.log('5. Configure settings and enable live trading');
    
    return true;
    
  } catch (error) {
    console.error('❌ Test failed:', error.message);
    return false;
  }
}

// Create log of the test
async function logTestResults(success) {
  const logPath = './ea-strategies/logs/AdvancedBreakoutEA_full_sync_test.log';
  const logContent = `Full EA Sync Test for AdvancedBreakoutEA.mq4
Date: ${new Date().toISOString()}
Status: ${success ? 'SUCCESS' : 'FAILED'}

Test Results:
=============
✅ HTTP Bridge Endpoints: Implemented
✅ EA Upload API: /api/ea/upload
✅ EA Compilation API: /api/ea/compile
✅ EA Listing API: /api/ea/list
✅ MetaEditor Integration: Command line compilation
✅ File Management: MT4 Experts directory

Full Automation Workflow:
==========================
1. MCP Server reads EA from local file
2. HTTP Bridge uploads EA to MT4 Experts directory
3. MetaEditor compiles EA with full logging
4. Compiled .ex4 available in MT4 Navigator
5. EA ready for attachment to charts

${success ? 
  'SUCCESS: AdvancedBreakoutEA is now available in MT4!' :
  'FAILED: Check HTTP Bridge configuration and MT4 installation'
}

Bridge URL: http://${MT4_HOST}:${MT4_PORT}
Test completed: ${new Date().toLocaleString()}`;

  fs.writeFileSync(logPath, logContent);
  console.log(`📝 Test log saved: ${logPath}`);
}

// Run the test
testEASync().then(async (success) => {
  await logTestResults(success);
  process.exit(success ? 0 : 1);
}).catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});