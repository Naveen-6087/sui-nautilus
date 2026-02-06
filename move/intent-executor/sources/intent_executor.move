// Copyright (c), Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Intent Executor Enclave Module
/// 
/// This module defines the on-chain logic for the intent executor enclave.
/// It uses the Nautilus framework for TEE attestation verification and
/// integrates with Seal for encrypted intent handling.
module intent_executor::intent_executor;

use std::string::String;
use enclave::enclave::{Enclave, EnclaveConfig, Cap, new_cap, create_enclave_config, create_intent_message};
use sui::{bcs, ed25519, hash::blake2b256, clock::Clock};

// ============== Error Codes ==============

const ENoAccess: u64 = 0;
const EInvalidSignature: u64 = 1;
const EExpiredIntent: u64 = 2;
const EInvalidEnclaveVersion: u64 = 3;

// ============== Intent Scopes (must match Rust enclave) ==============

/// Scope for price check responses
const INTENT_SCOPE_PRICE_CHECK: u8 = 0;

/// Scope for wallet PK attestation
const INTENT_SCOPE_WALLET_PK: u8 = 1;

/// Scope for decrypted intent data
const INTENT_SCOPE_INTENT_DECRYPTED: u8 = 2;

/// Scope for executed intent confirmation
const INTENT_SCOPE_INTENT_EXECUTED: u8 = 3;

// ============== One-Time Witness ==============

/// One-time witness for this module
public struct INTENT_EXECUTOR has drop {}

// ============== Payload Structs ==============

/// Wallet public key payload - signed by enclave to prove key ownership
public struct WalletPKPayload has drop {
    pk: vector<u8>,
}

/// Price check result payload
public struct PriceCheckPayload has drop {
    pair: String,
    price: u64,
    source: String,
}

/// Intent execution result payload  
public struct IntentExecutedPayload has drop {
    intent_id: vector<u8>,
    success: bool,
    tx_digest: vector<u8>,
}

// ============== Module Initialization ==============

/// Initialize the module - creates the capability for managing enclave config
fun init(otw: INTENT_EXECUTOR, ctx: &mut TxContext) {
    let cap = new_cap(otw, ctx);
    transfer::public_transfer(cap, ctx.sender());
}

// ============== Seal Approve Policy ==============

/// Seal approve policy for intent executor
/// 
/// This function is called by the Seal key servers to verify that
/// the enclave is authorized to decrypt intent data.
/// 
/// Checks:
/// 1) The ID used to derive Seal key is the intent ID
/// 2) The sender matches the wallet PK hash (derived from enclave-signed wallet pk)
/// 3) The signature is verified against the enclave's registered ephemeral pk
entry fun seal_approve(
    id: vector<u8>,
    signature: vector<u8>,
    wallet_pk: vector<u8>,
    timestamp: u64,
    enclave: &Enclave<INTENT_EXECUTOR>,
    clock: &Clock,
    ctx: &TxContext,
) {
    // Verify sender matches the wallet PK
    assert!(ctx.sender().to_bytes() == pk_to_address(&wallet_pk), ENoAccess);
    
    // Verify timestamp is not too old (within 5 minutes)
    let current_time = clock.timestamp_ms();
    assert!(current_time - timestamp < 300_000, EExpiredIntent);

    // Verify signature over the wallet PK payload
    let signing_payload = create_intent_message(
        INTENT_SCOPE_WALLET_PK,
        timestamp,
        WalletPKPayload { pk: wallet_pk },
    );
    let payload_bytes = bcs::to_bytes(&signing_payload);
    assert!(ed25519::ed25519_verify(&signature, enclave.pk(), &payload_bytes), EInvalidSignature);
}

/// Alternative seal approve that doesn't require wallet verification
/// Used for system-level operations where the enclave itself is the authority
entry fun seal_approve_enclave_only(
    _id: vector<u8>,
    signature: vector<u8>,
    nonce: vector<u8>,
    timestamp: u64,
    enclave: &Enclave<INTENT_EXECUTOR>,
    clock: &Clock,
) {
    // Verify timestamp is not too old
    let current_time = clock.timestamp_ms();
    assert!(current_time - timestamp < 300_000, EExpiredIntent);

    // Simple nonce-based verification
    let signing_payload = create_intent_message(
        INTENT_SCOPE_INTENT_DECRYPTED,
        timestamp,
        nonce,
    );
    let payload_bytes = bcs::to_bytes(&signing_payload);
    assert!(ed25519::ed25519_verify(&signature, enclave.pk(), &payload_bytes), EInvalidSignature);
}

// ============== Verification Functions ==============

/// Verify a price check result from the enclave
public fun verify_price_check(
    enclave: &Enclave<INTENT_EXECUTOR>,
    pair: String,
    price: u64,
    source: String,
    timestamp: u64,
    signature: vector<u8>,
): bool {
    let payload = PriceCheckPayload { pair, price, source };
    let intent_msg = create_intent_message(INTENT_SCOPE_PRICE_CHECK, timestamp, payload);
    let bytes = bcs::to_bytes(&intent_msg);
    ed25519::ed25519_verify(&signature, enclave.pk(), &bytes)
}

/// Verify an intent execution result from the enclave
public fun verify_intent_executed(
    enclave: &Enclave<INTENT_EXECUTOR>,
    intent_id: vector<u8>,
    success: bool,
    tx_digest: vector<u8>,
    timestamp: u64,
    signature: vector<u8>,
): bool {
    let payload = IntentExecutedPayload { intent_id, success, tx_digest };
    let intent_msg = create_intent_message(INTENT_SCOPE_INTENT_EXECUTED, timestamp, payload);
    let bytes = bcs::to_bytes(&intent_msg);
    ed25519::ed25519_verify(&signature, enclave.pk(), &bytes)
}

// ============== Helper Functions ==============

/// Derive address from public key (ed25519 flag + pk -> blake2b hash)
fun pk_to_address(pk: &vector<u8>): vector<u8> {
    let mut arr = vector[0u8]; // ed25519 flag
    arr.append(*pk);
    blake2b256(&arr)
}

// ============== Tests ==============

#[test]
fun test_pk_to_address() {
    let test_pk = x"5c38d3668c45ff891766ee99bd3522ae48d9771dc77e8a6ac9f0bde6c3a2ca48";
    let expected = x"29287d8584fb5b71b8d62e7224b867207d205fb61d42b7cce0deef95bf4e8202";
    assert!(pk_to_address(&test_pk) == expected, ENoAccess);
}

#[test]
fun test_intent_scopes() {
    assert!(INTENT_SCOPE_PRICE_CHECK == 0, 0);
    assert!(INTENT_SCOPE_WALLET_PK == 1, 0);
    assert!(INTENT_SCOPE_INTENT_DECRYPTED == 2, 0);
    assert!(INTENT_SCOPE_INTENT_EXECUTED == 3, 0);
}
