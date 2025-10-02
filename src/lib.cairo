use starknet::{ContractAddress, get_caller_address, get_block_timestamp};

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer_from(
        ref self: TContractState, 
        sender: ContractAddress, 
        recipient: ContractAddress, 
        amount: u256
    ) -> bool;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
}

#[derive(Drop, Copy, Serde, starknet::Store)]
#[allow(starknet::store_no_default_variant)]
enum TradeStatus {
    Created,
    Funded,
    Shipped,
    Delivered,
    Completed,
    Disputed,
    Cancelled,
}

#[derive(Drop, Copy, Serde, starknet::Store)]
#[allow(starknet::store_no_default_variant)]
enum InspectionStatus {
    Pending,
    Passed,
    Failed,
    NotRequired,
}

#[derive(Drop, Copy, Serde, starknet::Store)]
struct Trade {
    id: u256,
    buyer: ContractAddress,
    seller: ContractAddress,
    total_amount: u256,
    deposit_amount: u256,
    shipment_amount: u256,
    delivery_amount: u256,
    status: TradeStatus,
    inspection_status: InspectionStatus,
    tracking_number: ByteArray,
    quality_standards: ByteArray,
    created_at: u64,
    delivery_deadline: u64,
    quality_inspection_required: bool,
    inspector: ContractAddress,
}

#[derive(Drop, Copy, Serde, starknet::Store)]
struct UserProfile {
    bvn: felt252,
    is_verified: bool,
    total_trades: u256,
    successful_trades: u256,
    reputation_score: u256,
    joined_at: u64,
}

#[starknet::interface]
trait IPaySlab<TContractState> {
    fn verify_user(ref self: TContractState, bvn: felt252);
    fn create_trade(
        ref self: TContractState,
        seller: ContractAddress,
        total_amount: u256,
        delivery_deadline: u64,
        quality_standards: ByteArray,
        quality_inspection_required: bool
    ) -> u256;
    fn fund_trade(ref self: TContractState, trade_id: u256);
    fn mark_shipped(ref self: TContractState, trade_id: u256, tracking_number: ByteArray);
    fn confirm_delivery(ref self: TContractState, trade_id: u256);
    fn complete_quality_inspection(
        ref self: TContractState, 
        trade_id: u256, 
        status: InspectionStatus
    );
    fn dispute_trade(ref self: TContractState, trade_id: u256, reason: ByteArray);
    fn cancel_trade(ref self: TContractState, trade_id: u256);
    fn add_inspector(ref self: TContractState, inspector: ContractAddress);
    fn remove_inspector(ref self: TContractState, inspector: ContractAddress);
    fn update_platform_fee(ref self: TContractState, new_fee_rate: u256);
    fn update_fee_collector(ref self: TContractState, new_collector: ContractAddress);
    
    // View functions
    fn get_trade(self: @TContractState, trade_id: u256) -> Trade;
    fn get_user_profile(self: @TContractState, user: ContractAddress) -> UserProfile;
    fn get_user_reputation_score(self: @TContractState, user: ContractAddress) -> u256;
    fn is_user_verified(self: @TContractState, user: ContractAddress) -> bool;
    fn get_usdc_address(self: @TContractState) -> ContractAddress;
    fn get_platform_fee_rate(self: @TContractState) -> u256;
    fn get_fee_collector(self: @TContractState) -> ContractAddress;
    fn get_owner(self: @TContractState) -> ContractAddress;
}

#[starknet::contract]
mod PaySlab {
    use super::{
        ContractAddress, get_caller_address, get_block_timestamp,
        Trade, TradeStatus, InspectionStatus, UserProfile, IERC20Dispatcher, 
        IERC20DispatcherTrait
    };
    use core::num::traits::Zero;
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, Map, StoragePathEntry
    };

    #[storage]
    struct Storage {
        usdc: ContractAddress,
        platform_fee_rate: u256,
        fee_collector: ContractAddress,
        owner: ContractAddress,
        
        trades: Map<u256, Trade>,
        user_profiles: Map<ContractAddress, UserProfile>,
        used_bvns: Map<felt252, u8>,
        all_bvns: Map<ContractAddress, u8>,
        authorized_inspectors: Map<ContractAddress, u8>,
        
        next_trade_id: u256,
        reputation_base: u256,
        reentrancy_guard: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        TradeCreated: TradeCreated,
        TradeFunded: TradeFunded,
        TradeShipped: TradeShipped,
        TradeDelivered: TradeDelivered,
        TradeCompleted: TradeCompleted,
        TradeDisputed: TradeDisputed,
        TradeCancelled: TradeCancelled,
        PaymentReleased: PaymentReleased,
        UserVerified: UserVerified,
        QualityInspectionCompleted: QualityInspectionCompleted,
    }

    #[derive(Drop, starknet::Event)]
    struct TradeCreated {
        #[key]
        trade_id: u256,
        #[key]
        buyer: ContractAddress,
        #[key]
        seller: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, Copy, starknet::Event)]
    struct TradeFunded {
        #[key]
        trade_id: u256,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct TradeShipped {
        #[key]
        trade_id: u256,
        tracking_number: ByteArray,
    }

    #[derive(Drop, starknet::Event)]
    struct TradeDelivered {
        #[key]
        trade_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct TradeCompleted {
        #[key]
        trade_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct TradeDisputed {
        #[key]
        trade_id: u256,
        reason: ByteArray,
    }

    #[derive(Drop, starknet::Event)]
    struct TradeCancelled {
        #[key]
        trade_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct PaymentReleased {
        #[key]
        trade_id: u256,
        #[key]
        recipient: ContractAddress,
        amount: u256,
        milestone: ByteArray,
    }

    #[derive(Drop, Copy, starknet::Event)]
    struct UserVerified {
        #[key]
        user: ContractAddress,
        bvn: felt252,
    }

    #[derive(Drop, Copy, starknet::Event)]
    struct QualityInspectionCompleted {
        #[key]
        trade_id: u256,
        status: InspectionStatus,
        inspector: ContractAddress,
    }

    // Custom errors
    mod Errors {
        pub const TRADE_NOT_FOUND: felt252 = 'Trade not found';
        pub const UNAUTHORIZED_ACCESS: felt252 = 'Unauthorized access';
        pub const INVALID_TRADE_STATUS: felt252 = 'Invalid trade status';
        pub const INSUFFICIENT_FUNDS: felt252 = 'Insufficient funds';
        pub const BVN_ALREADY_USED: felt252 = 'BVN already used';
        pub const USER_NOT_VERIFIED: felt252 = 'User not verified';
        pub const INVALID_MILESTONE: felt252 = 'Invalid milestone';
        pub const DELIVERY_DEADLINE_EXCEEDED: felt252 = 'Delivery deadline exceeded';
        pub const INVALID_BVN_LENGTH: felt252 = 'Invalid BVN length';
        pub const REENTRANCY_DETECTED: felt252 = 'Reentrancy detected';
        pub const TRANSFER_FAILED: felt252 = 'Transfer failed';
        pub const FEE_TOO_HIGH: felt252 = 'Fee too high';
    }

    // Helper: compare two u256 values
    fn u256_lt(a: u256, b: u256) -> bool {
        let u256 { low: a_low, high: a_high } = a;
        let u256 { low: b_low, high: b_high } = b;
        if a_high < b_high { return true; }
        if a_high > b_high { return false; }
        a_low < b_low
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        usdc: ContractAddress,
        platform_fee_rate: u256,
        fee_collector: ContractAddress,
        owner: ContractAddress
    ) {
        self.usdc.write(usdc);
        self.platform_fee_rate.write(platform_fee_rate);
        self.fee_collector.write(fee_collector);
        self.owner.write(owner);
        self.next_trade_id.write(u256{ low: 1, high: 0 });
        self.reputation_base.write(u256{ low: 1000, high: 0 });
        self.reentrancy_guard.write(false);
    }

    #[abi(embed_v0)]
    impl PaySlabImpl of super::IPaySlab<ContractState> {
        fn verify_user(ref self: ContractState, bvn: felt252) {
            let caller = get_caller_address();
            assert(self.used_bvns.entry(bvn).read() == 0_u8, Errors::BVN_ALREADY_USED);
            self.used_bvns.entry(bvn).write(1_u8);

            let profile = UserProfile {
                bvn,
                is_verified: true,
                total_trades: u256{ low: 0, high: 0 },
                successful_trades: u256{ low: 0, high: 0 },
                reputation_score: u256{ low: 500, high: 0 }, // Start with 500/1000
                joined_at: get_block_timestamp(),
            };

            self.user_profiles.entry(caller).write(profile);
            self.emit(UserVerified { user: caller, bvn });
        }

        fn create_trade(
            ref self: ContractState,
            seller: ContractAddress,
            total_amount: u256,
            delivery_deadline: u64,
            quality_standards: ByteArray,
            quality_inspection_required: bool
        ) -> u256 {
            let caller = get_caller_address();
            let buyer_profile = self.user_profiles.entry(caller).read();
            let seller_profile = self.user_profiles.entry(seller).read();

            assert(buyer_profile.is_verified, Errors::USER_NOT_VERIFIED);
            assert(seller_profile.is_verified, Errors::USER_NOT_VERIFIED);

            let trade_id = self.next_trade_id.read();
            self.next_trade_id.write(trade_id + u256{ low: 1, high: 0 });

            // Calculate milestone amounts (20%, 30%, 50%)
            let deposit_amount = (total_amount * u256{ low: 20, high: 0 }) / u256{ low: 100, high: 0 };
            let shipment_amount = (total_amount * u256{ low: 30, high: 0 }) / u256{ low: 100, high: 0 };
            let delivery_amount = total_amount - deposit_amount - shipment_amount;

            let inspection_status = if quality_inspection_required {
                InspectionStatus::Pending
            } else {
                InspectionStatus::NotRequired
            };

            let trade = Trade {
                id: trade_id,
                buyer: caller,
                seller,
                total_amount,
                deposit_amount,
                shipment_amount,
                delivery_amount,
                status: TradeStatus::Created,
                inspection_status,
                tracking_number: "",
                quality_standards,
                created_at: get_block_timestamp(),
                delivery_deadline,
                quality_inspection_required,
                inspector: Zero::zero(),
            };

            self.trades.entry(trade_id).write(trade);
            self.emit(TradeCreated { trade_id, buyer: caller, seller, amount: total_amount });

            trade_id
        }

        fn fund_trade(ref self: ContractState, trade_id: u256) {
            self._check_reentrancy();
            self._set_reentrancy(true);

            let caller = get_caller_address();
            let mut trade = self.trades.entry(trade_id).read();

            assert(trade.id != u256{ low: 0, high: 0 }, Errors::TRADE_NOT_FOUND);
            assert(trade.buyer == caller, Errors::UNAUTHORIZED_ACCESS);
            match trade.status {
                TradeStatus::Created => {},
                _ => { core::panic_with_felt252(Errors::INVALID_TRADE_STATUS); }
            }

            // Transfer USDC from buyer to contract
            let usdc = IERC20Dispatcher { contract_address: self.usdc.read() };
            let transfer_success = usdc.transfer_from(
                caller, 
                starknet::get_contract_address(), 
                trade.total_amount
            );
            assert(transfer_success, Errors::TRANSFER_FAILED);

            trade = Trade { status: TradeStatus::Funded, ..trade };

            // Release 20% deposit to seller
            let deposit_amount = trade.deposit_amount;
            let fee = (deposit_amount * self.platform_fee_rate.read()) / u256{ low: 10000, high: 0 };
            let payment = deposit_amount - fee;

            assert(usdc.transfer(trade.seller, payment), Errors::TRANSFER_FAILED);
            assert(usdc.transfer(self.fee_collector.read(), fee), Errors::TRANSFER_FAILED);

            // Update user stats
            let mut buyer_profile = self.user_profiles.entry(caller).read();
            buyer_profile = UserProfile { 
                total_trades: buyer_profile.total_trades + u256{ low: 1, high: 0 }, 
                ..buyer_profile 
            };
            self.user_profiles.entry(caller).write(buyer_profile);

            let mut seller_profile = self.user_profiles.entry(trade.seller).read();
            seller_profile = UserProfile { 
                total_trades: seller_profile.total_trades + u256{ low: 1, high: 0 }, 
                ..seller_profile 
            };
            self.user_profiles.entry(trade.seller).write(seller_profile);

            self.trades.entry(trade_id).write(trade);

            self.emit(TradeFunded { trade_id, amount: trade.total_amount.clone() });
            self.emit(PaymentReleased { 
                trade_id, 
                recipient: trade.seller,
                amount: payment, 
                milestone: "DEPOSIT" 
            });

            self._set_reentrancy(false);
        }

        fn mark_shipped(ref self: ContractState, trade_id: u256, tracking_number: ByteArray) {
            let caller = get_caller_address();
            let mut trade = self.trades.entry(trade_id).read();

            assert(trade.id != u256{ low: 0, high: 0 }, Errors::TRADE_NOT_FOUND);
            assert(trade.seller == caller, Errors::UNAUTHORIZED_ACCESS);
            match trade.status {
                TradeStatus::Funded => {},
                _ => { core::panic_with_felt252(Errors::INVALID_TRADE_STATUS); }
            }

            trade = Trade { status: TradeStatus::Shipped, tracking_number: tracking_number.clone(), ..trade };

            // Calculate and release 30% shipment payment
            let shipment_amount = trade.shipment_amount;
            let fee = (shipment_amount * self.platform_fee_rate.read()) / u256{ low: 10000, high: 0 };
            let payment = shipment_amount - fee;

            let usdc = IERC20Dispatcher { contract_address: self.usdc.read() };
            assert(usdc.transfer(trade.seller, payment), Errors::TRANSFER_FAILED);
            assert(usdc.transfer(self.fee_collector.read(), fee), Errors::TRANSFER_FAILED);

            self.trades.entry(trade_id).write(trade);

            self.emit(TradeShipped { trade_id, tracking_number });
            self.emit(PaymentReleased { 
                trade_id, 
                recipient: trade.seller.clone(), 
                amount: payment, 
                milestone: "SHIPMENT" 
            });
        }

        fn confirm_delivery(ref self: ContractState, trade_id: u256) {
            let caller = get_caller_address();
            let mut trade = self.trades.entry(trade_id).read();

            assert(trade.id != u256{ low: 0, high: 0 }, Errors::TRADE_NOT_FOUND);
            assert(
                trade.buyer == caller || self.owner.read() == caller, 
                Errors::UNAUTHORIZED_ACCESS
            );
            match trade.status {
                TradeStatus::Shipped => {},
                _ => { core::panic_with_felt252(Errors::INVALID_TRADE_STATUS); }
            }

            trade = Trade { status: TradeStatus::Delivered, ..trade };
            self.trades.entry(trade_id).write(trade);

            self.emit(TradeDelivered { trade_id });

            // If quality inspection required, wait for inspection
            let is_pending = match trade.inspection_status { InspectionStatus::Pending => true, _ => false };
            if trade.quality_inspection_required && is_pending {
                return;
            }

            // Release final payment
            self._release_final_payment(trade_id);
        }

        fn complete_quality_inspection(
            ref self: ContractState, 
            trade_id: u256, 
            status: InspectionStatus
        ) {
            let caller = get_caller_address();
            let mut trade = self.trades.entry(trade_id).read();

            assert(trade.id != u256{ low: 0, high: 0 }, Errors::TRADE_NOT_FOUND);
            assert(self.authorized_inspectors.entry(caller).read() == 1_u8, Errors::UNAUTHORIZED_ACCESS);
            assert(trade.quality_inspection_required, Errors::INVALID_MILESTONE);

            trade = Trade { inspection_status: status, inspector: caller, ..trade };

            self.trades.entry(trade_id).write(trade);

            self.emit(QualityInspectionCompleted { trade_id, status: status, inspector: caller });

            // If delivered and inspection passed, release final payment
            let delivered = match trade.status { TradeStatus::Delivered => true, _ => false };
            let passed = match status { InspectionStatus::Passed => true, _ => false };
            if delivered && passed {
                self._release_final_payment(trade_id);
            }
        }

        fn dispute_trade(ref self: ContractState, trade_id: u256, reason: ByteArray) {
            let caller = get_caller_address();
            let mut trade = self.trades.entry(trade_id).read();

            assert(trade.id != u256{ low: 0, high: 0 }, Errors::TRADE_NOT_FOUND);
            assert(
                trade.buyer == caller || trade.seller == caller, 
                Errors::UNAUTHORIZED_ACCESS
            );
            match trade.status {
                TradeStatus::Completed => { core::panic_with_felt252(Errors::INVALID_TRADE_STATUS); },
                TradeStatus::Cancelled => { core::panic_with_felt252(Errors::INVALID_TRADE_STATUS); },
                _ => {}
            }

            trade = Trade { status: TradeStatus::Disputed, ..trade };
            self.trades.entry(trade_id).write(trade);

            self.emit(TradeDisputed { trade_id, reason });
        }

        fn cancel_trade(ref self: ContractState, trade_id: u256) {
            let caller = get_caller_address();
            let mut trade = self.trades.entry(trade_id).read();

            assert(trade.id != u256{ low: 0, high: 0 }, Errors::TRADE_NOT_FOUND);
            assert(
                trade.buyer == caller || self.owner.read() == caller, 
                Errors::UNAUTHORIZED_ACCESS
            );
            match trade.status {
                TradeStatus::Created => {},
                TradeStatus::Funded => {},
                _ => { core::panic_with_felt252(Errors::INVALID_TRADE_STATUS); }
            }

            // let trade_status = trade.status;

            let was_funded = match trade.status.clone() { TradeStatus::Funded => true, _ => false };
            trade = Trade { status: TradeStatus::Cancelled, ..trade };
            self.trades.entry(trade_id).write(trade);

            // Refund buyer if trade was funded
            if was_funded {
                let refund_amount = trade.total_amount - trade.deposit_amount;
                let usdc = IERC20Dispatcher { contract_address: self.usdc.read() };
                assert(usdc.transfer(trade.buyer, refund_amount), Errors::TRANSFER_FAILED);
            }

            self.emit(TradeCancelled { trade_id });
        }

        fn add_inspector(ref self: ContractState, inspector: ContractAddress) {
            self._only_owner();
            self.authorized_inspectors.entry(inspector).write(1_u8);
        }

        fn remove_inspector(ref self: ContractState, inspector: ContractAddress) {
            self._only_owner();
            self.authorized_inspectors.entry(inspector).write(0_u8);
        }

        fn update_platform_fee(ref self: ContractState, new_fee_rate: u256) {
            self._only_owner();
            assert(u256_lt(new_fee_rate, u256{ low: 501, high: 0 }), Errors::FEE_TOO_HIGH); // Max 5%
            self.platform_fee_rate.write(new_fee_rate);
        }

        fn update_fee_collector(ref self: ContractState, new_collector: ContractAddress) {
            self._only_owner();
            self.fee_collector.write(new_collector);
        }

        // View functions
        fn get_trade(self: @ContractState, trade_id: u256) -> Trade {
            self.trades.entry(trade_id).read()
        }

        fn get_user_profile(self: @ContractState, user: ContractAddress) -> UserProfile {
            self.user_profiles.entry(user).read()
        }

        fn get_user_reputation_score(self: @ContractState, user: ContractAddress) -> u256 {
            self.user_profiles.entry(user).read().reputation_score
        }

        fn is_user_verified(self: @ContractState, user: ContractAddress) -> bool {
            self.user_profiles.entry(user).read().is_verified
        }

        fn get_usdc_address(self: @ContractState) -> ContractAddress {
            self.usdc.read()
        }

        fn get_platform_fee_rate(self: @ContractState) -> u256 {
            self.platform_fee_rate.read()
        }

        fn get_fee_collector(self: @ContractState) -> ContractAddress {
            self.fee_collector.read()
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _only_owner(self: @ContractState) {
            assert(get_caller_address() == self.owner.read(), Errors::UNAUTHORIZED_ACCESS);
        }

        fn _check_reentrancy(self: @ContractState) {
            assert(!self.reentrancy_guard.read(), Errors::REENTRANCY_DETECTED);
        }

        fn _set_reentrancy(ref self: ContractState, value: bool) {
            self.reentrancy_guard.write(value);
        }

        fn _release_final_payment(ref self: ContractState, trade_id: u256) {
            let mut trade = self.trades.entry(trade_id).read();
            trade = Trade { status: TradeStatus::Completed, ..trade };

            let delivery_amount = trade.delivery_amount;
            let platform_fee = (delivery_amount * self.platform_fee_rate.read()) / u256{ low: 10000, high: 0 };
            let seller_amount = delivery_amount - platform_fee;

            let usdc = IERC20Dispatcher { contract_address: self.usdc.read() };
            assert(usdc.transfer(trade.seller, seller_amount), Errors::TRANSFER_FAILED);
            assert(usdc.transfer(self.fee_collector.read(), platform_fee), Errors::TRANSFER_FAILED);

            // Update reputation scores
            self._update_reputation_scores(trade.buyer, trade.seller, true);

            self.trades.entry(trade_id).write(trade);

            self.emit(PaymentReleased { 
                trade_id, 
                recipient: trade.seller.clone(), 
                amount: seller_amount, 
                milestone: "DELIVERY" 
            });
            self.emit(TradeCompleted { trade_id });
        }

        fn _update_reputation_scores(
            ref self: ContractState, 
            buyer: ContractAddress, 
            seller: ContractAddress, 
            success: bool
        ) {
            let mut buyer_profile = self.user_profiles.entry(buyer).read();
            let mut seller_profile = self.user_profiles.entry(seller).read();

            if success {
                buyer_profile = UserProfile { 
                    successful_trades: buyer_profile.successful_trades + u256{ low: 1, high: 0 }, 
                    ..buyer_profile 
                };
                seller_profile = UserProfile { 
                    successful_trades: seller_profile.successful_trades + u256{ low: 1, high: 0 }, 
                    ..seller_profile 
                };

                // Increase reputation (max 1000)
                if u256_lt(buyer_profile.reputation_score, u256{ low: 1000, high: 0 }) {
                    buyer_profile = UserProfile { 
                        reputation_score: buyer_profile.reputation_score + u256{ low: 10, high: 0 }, 
                        ..buyer_profile 
                    };
                }
                if u256_lt(seller_profile.reputation_score, u256{ low: 1000, high: 0 }) {
                    seller_profile = UserProfile { 
                        reputation_score: seller_profile.reputation_score + u256{ low: 10, high: 0 }, 
                        ..seller_profile 
                    };
                }
            } else {
                // Decrease reputation for failed trades
                let ten = u256{ low: 10, high: 0 };
                let buyer_gt = !u256_lt(buyer_profile.reputation_score, ten);
                let seller_gt = !u256_lt(seller_profile.reputation_score, ten);
                if buyer_gt {
                    buyer_profile = UserProfile { 
                        reputation_score: buyer_profile.reputation_score - ten, 
                        ..buyer_profile 
                    };
                }
                if seller_gt {
                    seller_profile = UserProfile { 
                        reputation_score: seller_profile.reputation_score - ten, 
                        ..seller_profile 
                    };
                }
            }

            self.user_profiles.entry(buyer).write(buyer_profile);
            self.user_profiles.entry(seller).write(seller_profile);
        }
    }
}