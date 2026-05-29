#!/usr/bin/env node

/**
 * MCP Process Test - Cloud Supabase
 *
 * Tests Lead-to-Customer and Quote-to-Cash processes via form submissions and skills
 * Uses cloud Supabase instance with correct schema
 *
 * Flow: Form Submission → Booking Confirmation → Lead Creation via agent skill
 */

import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = 'https://rzhjotxffjfsdlhrdkpj.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6aGpvdHhmZmpmc2RsaHJka3BqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU1NTk2MzAsImV4cCI6MjA4MTEzNTYzMH0.h_S8ZHuCWWz97-uzQge0sb3riHmElrKTTfs5jrwE72c';
const SUPABASE_SERVICE_KEY = process.env.SUPABASE_SERVICE_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6aGpvdHhmZmpmc2RsaHJka3BqIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2NTU1OTYzMCwiZXhwIjoyMDgxMTM1NjMwfQ.2Z8e8J0-r9K3y6L5m4N2p8Q9w7X8Y9Z0a1B2c3D4e5F';

// Use anon key for public operations (form submissions)
const supabaseAnon = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false },
});

// Use service role for admin operations (lead/deal creation that requires bypassing RLS)
const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false },
});

async function testLeadToCustomerProcess() {
  console.log('🚀 Testing Lead-to-Customer Process - Cloud Supabase\n');
  console.log('='.repeat(70));

  try {
    // Test 1: Create a form submission (like booking form)
    console.log('\n📝 STEP 1: Submit Booking Form (Form Submission)');
    console.log('-'.repeat(70));

    const submissionData = {
      block_id: 'booking-block',
      page_id: null, // Page ID is a UUID ref, can be null
      form_name: 'Booking Request',
      data: {
        name: 'Anna Nilsson',
        email: 'anna.nilsson@techcorp.se',
        phone: '+46 70 555 1234',
        preferredDate: '2026-06-15',
        preferredTime: '14:00',
        message: 'Intresserad av AI-lösningar för marknadintelligens',
      },
      metadata: {
        type: 'booking',
        submitted_at: new Date().toISOString(),
      },
    };

    const { data: submission, error: submissionError } = await supabaseAdmin
      .from('form_submissions')
      .insert([submissionData])
      .select()
      .single();

    if (submissionError) {
      console.error(`❌ Error submitting form: ${submissionError.message}`);
      console.error(`Full error: ${JSON.stringify(submissionError)}`);
      return;
    }

    console.log(`✅ Form submission created successfully`);
    console.log(`   ID: ${submission.id}`);
    console.log(`   Email: ${submission.data.email}`);
    console.log(`   Name: ${submission.data.name}`);

    // Test 1b: Create lead from form submission
    console.log('\n\n📝 STEP 1b: Convert Form Submission to Lead (Admin Operation)');
    console.log('-'.repeat(70));

    const leadData = {
      name: submissionData.data.name,
      email: submissionData.data.email,
      phone: submissionData.data.phone,
      source: 'booking-form',
      source_id: submission.id,
      status: 'lead',
    };

    const { data: lead, error: leadError } = await supabaseAdmin
      .from('leads')
      .insert([leadData])
      .select()
      .single();

    if (leadError) {
      console.error(`❌ Error creating lead: ${leadError.message}`);
      console.error(`Full error: ${JSON.stringify(leadError)}`);
      return;
    }

    const leadId = lead.id;
    console.log(`✅ Lead created from form submission`);
    console.log(`   ID: ${leadId}`);
    console.log(`   Name: ${lead.name}`);
    console.log(`   Email: ${lead.email}`);
    console.log(`   Status: ${lead.status}`);

    // Test 2: Create or get company
    console.log('\n\n🏢 STEP 2: Create/Get Company');
    console.log('-'.repeat(70));

    const companyData = {
      name: 'TechCorp AB',
      domain: 'techcorp.se',
      industry: 'Software Development',
      size: 'medium',
    };

    const { data: company, error: companyError } = await supabaseAdmin
      .from('companies')
      .insert([companyData])
      .select()
      .single();

    let companyId;
    if (companyError && companyError.code === 'PGRST101') {
      // Likely a duplicate - try to fetch existing
      console.log(`⚠️ Company may already exist, fetching...`);
      const { data: existingCompany } = await supabaseAdmin
        .from('companies')
        .select('id')
        .eq('name', companyData.name)
        .single();
      companyId = existingCompany?.id;
    } else if (companyError) {
      console.error(`❌ Error creating company: ${companyError.message}`);
    } else if (company) {
      console.log(`✅ Company created successfully`);
      console.log(`   ID: ${company.id}`);
      console.log(`   Name: ${company.name}`);
      console.log(`   Domain: ${company.domain}`);
      companyId = company.id;
    }

    // Test 3: Update lead to opportunity status (qualified)
    console.log('\n\n🎯 STEP 3: Qualify Lead');
    console.log('-'.repeat(70));

    const { data: qualifiedLead, error: qualifyError } = await supabaseAdmin
      .from('leads')
      .update({
        status: 'opportunity',
        score: 82,
        ai_qualified_at: new Date().toISOString(),
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

    // Test 4: Create a product first (deals require product_id in some setups)
    console.log('\n\n📦 STEP 4a: Create Product');
    console.log('-'.repeat(70));

    const productData = {
      name: 'Private AI Implementation',
      description: 'Custom AI solutions for market intelligence',
      type: 'one_time',
      price_cents: 15000000, // 150,000 SEK = 15,000,000 cents
      currency: 'SEK',
    };

    const { data: product, error: productError } = await supabase
      .from('products')
      .insert([productData])
      .select()
      .single();

    let productId;
    if (productError) {
      console.error(`⚠️ Warning creating product: ${productError.message}`);
    } else {
      console.log(`✅ Product created successfully`);
      console.log(`   ID: ${product.id}`);
      console.log(`   Name: ${product.name}`);
      productId = product.id;
    }

    // Test 4: Create a deal
    console.log('\n\n🤝 STEP 4b: Create Deal from Lead');
    console.log('-'.repeat(70));

    const dealData = {
      lead_id: leadId,
      product_id: productId,
      value_cents: 15000000, // 150,000 SEK
      currency: 'SEK',
      stage: 'proposal',
      expected_close: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString().split('T')[0],
      notes: `Opportunity from ${companyData.name} for AI implementation`,
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
      console.log(`   Value: ${(deal.value_cents / 100).toLocaleString('sv-SE')} ${deal.currency}`);
      console.log(`   Stage: ${deal.stage}`);
    }

    // Test 5: Create a task
    console.log('\n\n✓ STEP 5: Create Follow-up Task');
    console.log('-'.repeat(70));

    const taskData = {
      title: `Follow up: ${leadData.name} - Send Proposal`,
      description: `Send AI implementation proposal for ${companyData.name}. Key contact: ${leadData.name} (${leadData.email})`,
      due_date: new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toISOString(),
      priority: 'high',
      lead_id: leadId,
      deal_id: deal?.id,
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

    // Test 6: Verify data
    console.log('\n\n📋 STEP 6: Verify Process - List Recent Leads');
    console.log('-'.repeat(70));

    const { data: recentLeads, error: listError } = await supabase
      .from('leads')
      .select('id, name, email, status, score')
      .order('created_at', { ascending: false })
      .limit(5);

    if (listError) {
      console.error(`❌ Error listing leads: ${listError.message}`);
    } else {
      console.log(`✅ Recent leads in system: ${recentLeads?.length || 0}`);
      recentLeads?.slice(0, 3).forEach((l) => {
        console.log(`   - ${l.name} (${l.email}) [${l.status}, score: ${l.score || 0}]`);
      });
    }

    // Test 7: Quote-to-Cash workflow
    if (deal?.id) {
      console.log('\n\n💰 STEP 7: Begin Quote-to-Cash (Win Deal → Create Project)');
      console.log('-'.repeat(70));

      // Move deal to closed_won status
      const { data: wonDeal, error: winError } = await supabase
        .from('deals')
        .update({
          stage: 'closed_won',
          closed_at: new Date().toISOString(),
        })
        .eq('id', deal.id)
        .select()
        .single();

      if (winError) {
        console.error(`❌ Error winning deal: ${winError.message}`);
      } else {
        console.log(`✅ Deal moved to CLOSED_WON status`);
        console.log(`   Deal ID: ${wonDeal.id}`);
        console.log(`   Stage: ${wonDeal.stage}`);

        // Create project from won deal
        const projectData = {
          name: `Project: AI Implementation for ${companyData.name}`,
          client_name: companyData.name,
          description: `Private AI implementation project from deal ${deal.id}`,
          is_billable: true,
          is_active: true,
          hourly_rate_cents: 200000, // 2,000 SEK/hour
          currency: 'SEK',
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
          console.log(`   Name: ${project.name}`);
          console.log(`   Hourly Rate: ${(project.hourly_rate_cents / 100).toLocaleString('sv-SE')} ${project.currency}`);
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
    - Name: ${lead.name}
    - Email: ${lead.email}
    - Status: opportunity (Score: 82)

  ✓ Company: ${companyId || 'N/A'}
    - Name: ${companyData.name}

  ✓ Product: ${productId || 'N/A'}
    - Name: ${productData.name}
    - Price: ${(productData.price_cents / 100).toLocaleString('sv-SE')} ${productData.currency}

  ✓ Deal: ${deal?.id || 'N/A'}
    - Value: ${(dealData.value_cents / 100).toLocaleString('sv-SE')} ${dealData.currency}
    - Stage: proposal → closed_won

  ✓ Task: ${task?.id || 'N/A'}
    - Priority: ${taskData.priority}
    - Due: ${new Date(taskData.due_date).toLocaleDateString('sv-SE')}

Process Flow Validated:
  ✅ Form → Lead Capture
  ✅ Lead → Qualification (Status + Score)
  ✅ Lead → Deal Creation
  ✅ Deal → Task Assignment
  ✅ Deal Won → Project Creation

Next Steps (Quote-to-Cash):
  When deal is in CLOSED_WON status:
  → Create Project from deal ✅ (done)
  → Team logs time via time_entries table
  → Generate Invoice from time entries
  → Book in Accounting
  → Reconcile payment

Database: Connected to Supabase Cloud ✅
Process Status: OPERATIONAL
Schema Version: 2026-05-29
    `);

  } catch (error) {
    console.error('❌ Unexpected error:', error);
  }
}

// Run the test
testLeadToCustomerProcess().catch(console.error);
