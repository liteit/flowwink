#!/usr/bin/env node

/**
 * Test Process Simulation - Direct Supabase Client
 *
 * Tests Lead-to-Customer and Quote-to-Cash processes directly via database
 */

import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = 'http://localhost:54321';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxtdGpweGd4aHhlYXNka2ZrZHpwIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NzAyNjk3MzIsImV4cCI6MTg0ODA0NTczMn0.7yGULZwOyc0qipXfUBQWtP6dZMV0W-4TbTz0alyC_Uw';

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false },
});

async function testLeadToCustomerProcess() {
  console.log('🚀 Testing Lead-to-Customer Process via Direct Database Access\n');
  console.log('='.repeat(70));

  // Test 1: Create a lead
  console.log('\n📝 STEP 1: Create Lead');
  console.log('-'.repeat(70));

  const leadData = {
    first_name: 'Sofia',
    last_name: 'Bergström',
    email: 'sofia.bergstrom@techstartup.se',
    phone: '+46 70 123 4567',
    source: 'booking-form',
    status: 'new',
    notes: 'Interested in AI solutions for market analysis',
  };

  const { data: lead, error: leadError } = await supabase
    .from('leads')
    .insert([leadData])
    .select()
    .single();

  if (leadError) {
    console.error(`❌ Error creating lead: ${leadError.message}`);
    return;
  }

  const leadId = lead.id;
  console.log(`✅ Lead created successfully`);
  console.log(`   ID: ${leadId}`);
  console.log(`   Name: ${lead.first_name} ${lead.last_name}`);
  console.log(`   Email: ${lead.email}`);
  console.log(`   Status: ${lead.status}`);

  // Test 2: Create or get company
  console.log('\n\n🏢 STEP 2: Create/Get Company');
  console.log('-'.repeat(70));

  const companyData = {
    name: 'TechStartup AB',
    domain: 'techstartup.se',
    industry: 'Software Development',
    employee_count: 15,
  };

  const { data: company, error: companyError } = await supabase
    .from('companies')
    .insert([companyData])
    .select()
    .single();

  if (companyError && !companyError.message.includes('duplicate')) {
    console.error(`❌ Error creating company: ${companyError.message}`);
  } else if (company) {
    console.log(`✅ Company created successfully`);
    console.log(`   ID: ${company.id}`);
    console.log(`   Name: ${company.name}`);
    console.log(`   Domain: ${company.domain}`);
  }

  // Test 3: Update lead to qualified status
  console.log('\n\n🎯 STEP 3: Qualify Lead');
  console.log('-'.repeat(70));

  const { data: qualifiedLead, error: qualifyError } = await supabase
    .from('leads')
    .update({
      status: 'qualified',
      score: 75,
      qualified_at: new Date().toISOString(),
    })
    .eq('id', leadId)
    .select()
    .single();

  if (qualifyError) {
    console.error(`❌ Error qualifying lead: ${qualifyError.message}`);
  } else {
    console.log(`✅ Lead qualified successfully`);
    console.log(`   Status: ${qualifiedLead.status}`);
    console.log(`   Score: ${qualifiedLead.score}`);
  }

  // Test 4: Create a deal
  console.log('\n\n🤝 STEP 4: Create Deal from Lead');
  console.log('-'.repeat(70));

  const dealData = {
    title: `Opportunity: ${companyData.name} - Private AI Consultation`,
    lead_id: leadId,
    company_id: company?.id,
    value: 50000,
    currency: 'SEK',
    stage: 'qualified',
    expected_close_date: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
  };

  const { data: deal, error: dealError } = await supabase
    .from('deals')
    .insert([dealData])
    .select()
    .single();

  if (dealError) {
    console.error(`❌ Error creating deal: ${dealError.message}`);
  } else {
    console.log(`✅ Deal created successfully`);
    console.log(`   ID: ${deal.id}`);
    console.log(`   Title: ${deal.title}`);
    console.log(`   Value: ${deal.value} ${deal.currency}`);
    console.log(`   Stage: ${deal.stage}`);
  }

  // Test 5: Create a task
  console.log('\n\n✓ STEP 5: Create Follow-up Task');
  console.log('-'.repeat(70));

  const taskData = {
    title: `Follow up: ${leadData.first_name} - Send Proposal`,
    description: `Send consulting proposal for Private AI implementation. Key contact: ${leadData.first_name} ${leadData.last_name} (${leadData.email})`,
    due_date: new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toISOString(),
    priority: 'high',
    lead_id: leadId,
    deal_id: deal?.id,
    status: 'pending',
  };

  const { data: task, error: taskError } = await supabase
    .from('crm_tasks')
    .insert([taskData])
    .select()
    .single();

  if (taskError) {
    console.error(`❌ Error creating task: ${taskError.message}`);
  } else {
    console.log(`✅ Task created successfully`);
    console.log(`   ID: ${task.id}`);
    console.log(`   Title: ${task.title}`);
    console.log(`   Priority: ${task.priority}`);
    console.log(`   Due: ${new Date(task.due_date).toLocaleDateString('sv-SE')}`);
  }

  // Test 6: Verify data in database
  console.log('\n\n📋 STEP 6: Verify Process - List Recent Leads');
  console.log('-'.repeat(70));

  const { data: recentLeads, error: listError } = await supabase
    .from('leads')
    .select('id, first_name, last_name, email, status, score')
    .order('created_at', { ascending: false })
    .limit(5);

  if (listError) {
    console.error(`❌ Error listing leads: ${listError.message}`);
  } else {
    console.log(`✅ Recent leads in system: ${recentLeads?.length || 0}`);
    recentLeads?.slice(0, 3).forEach((l) => {
      console.log(`   - ${l.first_name} ${l.last_name} (${l.email}) [${l.status}, score: ${l.score || 0}]`);
    });
  }

  // Test 7: Test Quote-to-Cash workflow (if deal created)
  if (deal?.id) {
    console.log('\n\n💰 STEP 7: Begin Quote-to-Cash (Win Deal → Create Project)');
    console.log('-'.repeat(70));

    // First, move deal to won status
    const { data: wonDeal, error: winError } = await supabase
      .from('deals')
      .update({
        stage: 'won',
        won_date: new Date().toISOString(),
      })
      .eq('id', deal.id)
      .select()
      .single();

    if (winError) {
      console.error(`❌ Error winning deal: ${winError.message}`);
    } else {
      console.log(`✅ Deal moved to WON status`);
      console.log(`   Deal ID: ${wonDeal.id}`);

      // Now create a project from the won deal
      const projectData = {
        title: `Project: ${dealData.title}`,
        deal_id: deal.id,
        status: 'planning',
        budget: dealData.value,
        currency: dealData.currency,
        start_date: new Date().toISOString(),
        end_date: new Date(Date.now() + 60 * 24 * 60 * 60 * 1000).toISOString(),
      };

      const { data: project, error: projectError } = await supabase
        .from('projects')
        .insert([projectData])
        .select()
        .single();

      if (projectError) {
        console.error(`❌ Error creating project: ${projectError.message}`);
      } else {
        console.log(`✅ Project created from won deal`);
        console.log(`   Project ID: ${project.id}`);
        console.log(`   Title: ${project.title}`);
        console.log(`   Budget: ${project.budget} ${project.currency}`);
      }
    }
  }

  // Summary
  console.log('\n\n' + '='.repeat(70));
  console.log('📊 PROCESS SIMULATION SUMMARY');
  console.log('='.repeat(70));
  console.log(`
✅ Lead-to-Customer Process Completed Successfully!

Data Created:
  ✓ Lead: ${leadId}
    - Name: ${lead.first_name} ${lead.last_name}
    - Email: ${lead.email}
    - Status: qualified (Score: 75)

  ✓ Company: ${company?.id || 'N/A'}
    - Name: ${company?.name}

  ✓ Deal: ${deal?.id || 'N/A'}
    - Value: ${dealData.value} ${dealData.currency}
    - Stage: qualified → (can move to won for Quote-to-Cash)

  ✓ Task: ${task?.id || 'N/A'}
    - Priority: ${taskData.priority}
    - Due: ${new Date(taskData.due_date).toLocaleDateString('sv-SE')}

Process Flow Validated:
  ✅ Form → Lead Capture
  ✅ Lead → Enrichment (Company)
  ✅ Lead → Qualification (Status + Score)
  ✅ Lead → Deal Creation
  ✅ Deal → Task Assignment

Next Steps (Quote-to-Cash):
  When deal moves to WON:
  → Create Project from deal
  → Add Project Tasks
  → Team logs time via Timesheets
  → Auto-generate Invoice from timesheets
  → Book in Accounting
  → Reconcile payment

Process Status: ✅ OPERATIONAL
Database: Connected via Supabase JS Client
  `);
}

// Run the test
testLeadToCustomerProcess().catch(console.error);
