use starknet::ContractAddress;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use pragma_lib::abi::{IPragmaABIDispatcher, IPragmaABIDispatcherTrait};
use pragma_lib::types::{AggregationMode, DataType, PragmaPricesResponse};
use starknet::ClassHash;
use starknet::syscalls::replace_class_syscall;
use ekubo::interfaces::erc20::IERC20Dispatcher;
use ekubo::interfaces::erc20::IERC20DispatcherTrait;

#[starknet::interface]
pub trait IHelloStarknet<TContractState> {
    fn register_user(ref self: TContractState, token_to_use: IERC20Dispatcher, token_to_repay: IERC20Dispatcher);
    fn register_user_if_needed(ref self: TContractState);

    // Deposit and borrow
    fn deposit_token(ref self: TContractState, token: IERC20Dispatcher, amount: u256);
    fn withdraw_token(ref self: TContractState, token: IERC20Dispatcher, amount: u256);
    fn borrow_token(ref self: TContractState, token: IERC20Dispatcher, amount: u256);
    fn repay_token(ref self: TContractState, token: IERC20Dispatcher, amount: u256);
    
    // Liquidation
    fn change_token_to_use(ref self: TContractState, token: IERC20Dispatcher);
    fn change_token_to_repay(ref self: TContractState, token: IERC20Dispatcher);
    
    // Info about user's position
    fn total_money_deposited(self: @TContractState, user: ContractAddress) -> u256;
    fn total_money_available_to_borrow(self: @TContractState, user: ContractAddress) -> u256;
    fn total_money_borrowed(self: @TContractState, user: ContractAddress) -> u256;

    // Interest rates
    fn supply_apy(self: @TContractState, token: IERC20Dispatcher) -> u256;
    fn borrow_apy(self: @TContractState, token: IERC20Dispatcher) -> u256;
    fn update_every_user_position(ref self: TContractState);
    fn update_user_position(ref self: TContractState, user: ContractAddress, n: u256); // Internal

    // Liquidation
    fn try_to_liq_user(ref self: TContractState, user: ContractAddress) -> bool; // Return if we have liquidated user
    fn do_we_liq(ref self: TContractState, user: ContractAddress) -> bool;
    fn try_to_liquidate_everyone(ref self: TContractState);
    fn liquidate(ref self: TContractState, user: ContractAddress, token_from: IERC20Dispatcher, token_to: IERC20Dispatcher, amount: u128);
    fn update_all_token_price(ref self: TContractState);
    
    // Helpers or debug functions
    fn frontend_get_asset_price(self: @TContractState, token: IERC20Dispatcher) -> u256;
    fn is_supported_token(self: @TContractState, token: IERC20Dispatcher) -> bool;

    // The global hook called everywhere
    fn hook(ref self: TContractState);

    // Points
    fn frontend_get_user_points(self: @TContractState, user: ContractAddress) -> u256;
    fn frontend_get_total_points(self: @TContractState) -> u256; // Total number of points
    fn increase_user_points(ref self: TContractState, user: ContractAddress, points: u256);
    fn set_user_points_to_0(ref self: TContractState, user: ContractAddress); // Only admin
    
    // Points campaign
    fn admin_create_new_points_campaign(self: @TContractState); // Only admin
    fn register_for_the_current_campaign(self: @TContractState); // Require a deposit
    fn admin_blacklist_user_campaign(self: @TContractState, user: ContractAddress); // Remove a lying user from the campaign
    fn admin_finish_point_campaign(ref self: TContractState, user: ContractAddress); // Todo args
    fn admin_dissalow_new_futur_points_campaign(self: @TContractState); // Only admin

    // Frontend functions - all of them fail, only called by the frontend not onchain
    // Actually they dont - yet
    fn frontend_get_number_of_users(self: @TContractState) -> u256;
    fn frontend_get_TLV(self: @TContractState) -> u256;
    fn frontend_deposited_amount(self: @TContractState, user: ContractAddress, token: IERC20Dispatcher) -> u256;
    fn frontend_borrowed_amount(self: @TContractState, user: ContractAddress, token: IERC20Dispatcher) -> u256;
    fn frontend_total_deposited_amount(self: @TContractState, token: IERC20Dispatcher) -> u256;
    fn frontend_total_borrowed_amount(self: @TContractState, token: IERC20Dispatcher) -> u256;
    fn frontend_utilisation_rate(self: @TContractState, user: ContractAddress) -> u256;
    fn frontend_utilisation_rate_after_deposit(self: @TContractState, user: ContractAddress, token: IERC20Dispatcher, amount: u256) -> u256;
    fn frontend_utilisation_rate_after_borrow(self: @TContractState, user: ContractAddress, token: IERC20Dispatcher, amount: u256) -> u256;
    fn frontend_utilisation_rate_after_repay(self: @TContractState, user: ContractAddress, token: IERC20Dispatcher, amount: u256) -> u256;

    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
    //fn set_price(ref self: TContractState, token: ContractAddress, value: u256);
    //fn liquidate_single_user(ref self: TContractState, user: ContractAddress);
}

#[starknet::contract]
mod HelloStarknet {
    use ddd::IHelloStarknet;
    use starknet::get_block_number;
    use starknet::storage_access::storage_base_address_from_felt252;
    use starknet::storage_access::storage_address_from_base_and_offset;
    use starknet::{ContractAddress, get_caller_address, get_contract_address, contract_address_const};

    use ekubo::interfaces::router::IRouterDispatcher;
    use ekubo::interfaces::router::IRouterDispatcherTrait;
    use ekubo::interfaces::router::TokenAmount;
    use super::PoolKey;
    use ekubo::types::i129::i129;
    use ekubo::types::delta::Delta;
    use ekubo::interfaces::router::RouteNode;
    use ekubo::interfaces::erc20::IERC20Dispatcher;
    use ekubo::interfaces::erc20::IERC20DispatcherTrait;
    use ekubo::components::clear::IClearDispatcher;
    use ekubo::components::clear::IClearDispatcherTrait;
    use super::{IPragmaABIDispatcher, IPragmaABIDispatcherTrait};
    use super::{AggregationMode, DataType, PragmaPricesResponse};
    use super::ClassHash;
    use super::replace_class_syscall;


    // Collateral factor
    // Todo verifier la formule dans le code
    const volatility_scale: u256 = 1000;
    const eth_collateral_factor: u256 = 900; // 90%
    const strk_collateral_factor: u256 = 900; // 90%
    const usdc_collateral_factor: u256 = 900; // 90%

    const min_sqrt_ratio_limit: u256 = 18446748437148339061;
    const max_sqrt_ratio_limit: u256 = 6277100250585753475930931601400621808602321654880405518632;

    const APY_SCALE: u256 = 100000;

    #[storage]
    struct Storage {

        ////////////////
        /// Map of users
        ////////////////

        // Map of address => id - need to register to create one
        next_id: felt252,
        map_users_id: LegacyMap::<felt252, ContractAddress>,
        map_users_exists: LegacyMap::<ContractAddress, bool>,
        map_users_deposited: LegacyMap::<(ContractAddress, ContractAddress), u256>,
        map_users_borrowed: LegacyMap::<(ContractAddress, ContractAddress), u256>,
        map_users_token_to_use: LegacyMap::<ContractAddress, ContractAddress>, // Token to use first when we liquidate
        map_users_token_to_repay: LegacyMap::<ContractAddress, ContractAddress>, // Token to repay first when we liq

        /////////////////
        /// Map of ntoken
        /////////////////

        // Tokens of our protocol - numerotation starts at 0
        // Total number of tokens of our protocol
        number_of_tokens: felt252,
        // First, a map to tokenAddress the address of the token
        map_tokens_to_tokenaddress: LegacyMap::<felt252, ContractAddress>,
        // Then,  a map to tokenAddress the address of the oracle we use (pragma)
        map_tokens_to_oraclekey:    LegacyMap::<ContractAddress, felt252>,
        // And,   a map to tokenAddress to the price of the token (retrieved from the oracle)
        map_tokens_to_price:        LegacyMap::<ContractAddress, u256>,
        // And,   a map to adjust value of token based on their volatility. To be divided by 
        map_tokens_to_collateral_factor: LegacyMap::<ContractAddress, u256>,
        // (token0, token1) to pool
        // Symetrical, so also has (token1, token0) that returns the same pool
        liquidation_pools: LegacyMap::<(ContractAddress, ContractAddress), (u128, u128)>,

        //////////////////
        /// Addresses
        //////////////////

        // Pragma oracle
        pragmaOracle: IPragmaABIDispatcher,

        // Ekubo AMM address
        ekuboRouter: IRouterDispatcher,

        ///////////
        /// Points
        ///////////
        map_users_points: LegacyMap::<ContractAddress, u256>,

        // Various vars
        are_we_in_hook: bool,
        last_interaction_with_the_protocol: u64, // block number

    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        
        // Map users
        self.next_id.write(0);

        // Map ntokens

        // Let's populate each map
        // USDC
        // Sepolia - the tokens used by ekubo - 0x07ab0b8855a61f480b4423c46c32fa7c553f0aac3531bbddaa282d86244f7a23
        // Mainnet - 0x053C91253BC9682c04929cA02ED00b3E423f6710D2ee7e0D5EBB06F3eCF368A8
        let contract_address = contract_address_const::<0x053C91253BC9682c04929cA02ED00b3E423f6710D2ee7e0D5EBB06F3eCF368A8>();
        let token = contract_address;
        self.map_tokens_to_tokenaddress.write(0, token);
        self.map_tokens_to_oraclekey.write(token, 'USDC/USD');
        self.map_tokens_to_collateral_factor.write(token, usdc_collateral_factor);

        // Eth
        let contract_address = contract_address_const::<0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>();
        let token = contract_address;
        self.map_tokens_to_tokenaddress.write(1, token);
        self.map_tokens_to_oraclekey.write(token, 'ETH/USD');
        self.map_tokens_to_collateral_factor.write(token, eth_collateral_factor);
        
        // Strk
        // STRK/USDC pool
        let contract_address = contract_address_const::<0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d>();
        let token = contract_address;
        self.map_tokens_to_tokenaddress.write(2, token);
        self.map_tokens_to_oraclekey.write(token, 'STRK/USD');
        self.map_tokens_to_collateral_factor.write(token, strk_collateral_factor);
        // How many tokens do we have: 3
        self.number_of_tokens.write(3);
        // Liquidation pools
        // So far, only strk, eth and usdc
        // let assets = array![
        //     contract_address_const::<0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d>(),
        //     contract_address_const::<0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>(),
        //     contract_address_const::<0x053C91253BC9682c04929cA02ED00b3E423f6710D2ee7e0D5EBB06F3eCF368A8>(),
        // ].span();
        // let size = assets.len();
        // let mut i_token1 = 0;
        // while i_token1 < size {
        //     let mut i_token0 = 0;
        //     while i_token0 < i_token0 {
        //         let token0 = assets[i_token0].clone();
        //         let token1 = assets[i_token1].clone();
        //         // In every case we have token0 < token1 - the requirement of ekubo
        //         let fee = 170141183460469235273462165868118016;
        //         let tick_spacing = 1000;
        //         let extension = contract_address_const::<0x0>();
        //         let pool = PoolKey { token0, token1, fee, tick_spacing, extension };
        //         self.liquidation_pools.write((token0, token1), pool);
        //         i_token0 += 1;
        //     };
        //     i_token1 += 1
        // };
        self.last_interaction_with_the_protocol.write(get_block_number());


        // Addresses

        // Sepolia: 0x36031daa264c24520b11d93af622c848b2499b66b41d611bac95e13cfca131a
        // Mainnet: 0x2a85bd616f912537c50a49a4076db02c00b29b2cdc8a197ce92ed1837fa875b
        let contract_address = contract_address_const::<0x2a85bd616f912537c50a49a4076db02c00b29b2cdc8a197ce92ed1837fa875b>();
        self.pragmaOracle.write(IPragmaABIDispatcher { contract_address });
        // With oracle: we can update every prices
        self.update_all_token_price();

        // Ekubo AMM
        // Sepolia: 0x0045f933adf0607292468ad1c1dedaa74d5ad166392590e72676a34d01d7b763
        // Mainnet: 0x0199741822c2dc722f6f605204f35e56dbc23bceed54818168c4c49e4fb8737e
        let contract_address = contract_address_const::<0x0199741822c2dc722f6f605204f35e56dbc23bceed54818168c4c49e4fb8737e>();
        self.ekuboRouter.write(IRouterDispatcher { contract_address });
    }

    #[abi(embed_v0)]
    impl HelloStarknetImpl of super::IHelloStarknet<ContractState> {
        fn register_user(ref self: ContractState, token_to_use: IERC20Dispatcher, token_to_repay: IERC20Dispatcher) {
            assert!(self.is_supported_token(token_to_use), "This token to use to repay is not supported by the protocol.");
            assert!(self.is_supported_token(token_to_repay), "This token we first repay is not supported by the protocol.");
            // Todo: ask for a fee
            let user = get_caller_address();
            let id_user: felt252 = self.next_id.read();
            self.next_id.write(id_user + 1);
            self.map_users_exists.write(user, true);
            self.map_users_id.write(id_user, user);
            self.map_users_token_to_use.write(user, token_to_use.contract_address);
            self.map_users_token_to_repay.write(user, token_to_repay.contract_address);
        }
        fn register_user_if_needed(ref self: ContractState) {
            let user = get_caller_address();
            if (!self.map_users_exists.read(user)) {
                let token_to_use = IERC20Dispatcher { contract_address: self.map_tokens_to_tokenaddress.read(0) };
                let token_to_repay = IERC20Dispatcher { contract_address: self.map_tokens_to_tokenaddress.read(1) };
                self.register_user(token_to_use, token_to_repay);
            }
        }
        fn deposit_token(ref self: ContractState, token: IERC20Dispatcher, amount: u256) {
            assert!(self.is_supported_token(token), "This token is not supported by the protocol.");
            self.register_user_if_needed();
            let user = get_caller_address();
            assert!(self.map_users_borrowed.read((user, token.contract_address)) == 0, "Sorry you can't deposit and borrow the same token");
            let contract = get_contract_address();
            assert!(token.allowance(user, contract) >= amount, "Please approve the contract to spend (some) of your tokens to deposit.");
            token.transferFrom(user, contract, amount);
            let old_amount = self.map_users_deposited.read((user, token.contract_address));
            self.map_users_deposited.write((user, token.contract_address), old_amount + amount);
            // Increase user points
            let old_points = self.map_users_points.read(user);
            let delta_points = 10000 * amount * self.map_tokens_to_price.read(token.contract_address);
            self.map_users_points.write(user, old_points + delta_points);
            self.hook();
        }
        fn withdraw_token(ref self: ContractState, token: IERC20Dispatcher, amount: u256) {
            self.hook();
            assert!(self.is_supported_token(token), "This token is not supported by the protocol.");
            self.register_user_if_needed();
            let user = get_caller_address();
            token.transfer(user, amount);
            let old_amount = self.map_users_deposited.read((user, token.contract_address));
            self.map_users_deposited.write((user, token.contract_address), old_amount - amount);
            assert!(!self.do_we_liq(user), "You are above liquidation threshold, please withdraw less");
            // Set user points to 0
            self.map_users_points.write(user, 0);
        }
        fn borrow_token(ref self: ContractState, token: IERC20Dispatcher, amount: u256) {
            self.hook();
            assert!(self.is_supported_token(token), "This token is not supported by the protocol.");
            self.register_user_if_needed();
            let user = get_caller_address();
            assert!(self.map_users_deposited.read((user, token.contract_address)) == 0, "Sorry you can't deposit and borrow the same token");
            token.transfer(user, amount);
            let old_amount = self.map_users_borrowed.read((user, token.contract_address));
            self.map_users_borrowed.write((user, token.contract_address), old_amount + amount);
            assert!(!self.do_we_liq(user), "You are above liquidation threshold, please borrow less");
        }
        fn repay_token(ref self: ContractState, token: IERC20Dispatcher, amount: u256) {
            assert!(self.is_supported_token(token), "This token is not supported by the protocol.");
            self.register_user_if_needed();
            let user = get_caller_address();
            let contract = get_contract_address();
            assert!(token.allowance(user, contract) >= amount, "Please approve the contract to spend (some) of your tokens to deposit.");
            token.transferFrom(user, contract, amount);
            let old_amount = self.map_users_borrowed.read((user, token.contract_address));
            self.map_users_borrowed.write((user, token.contract_address), old_amount - amount);
            self.hook();
        }
        fn change_token_to_use(ref self: ContractState, token: IERC20Dispatcher) {
            self.hook();
            assert!(self.is_supported_token(token), "This token is not supported by the protocol.");
            self.register_user_if_needed();
            let user = get_caller_address();
            assert!(token.contract_address != self.map_users_token_to_repay.read(user), "Set a token to use different than your token to repay");
            self.map_users_token_to_use.write(user, token.contract_address);
        }
        fn change_token_to_repay(ref self: ContractState, token: IERC20Dispatcher) {
            self.hook();
            assert!(self.is_supported_token(token), "This token is not supported by the protocol.");
            self.register_user_if_needed();
            let user = get_caller_address();
            assert!(token.contract_address != self.map_users_token_to_use.read(user), "Set a token to repay different than your token to use");
            self.map_users_token_to_repay.write(user, token.contract_address);
        }

        fn total_money_deposited(self: @ContractState, user: ContractAddress) -> u256 {
            // Suppose prices are up to date
            assert!(self.map_users_exists.read(user), "Please register first before using the app");
            let mut value: u256 = 0;
            let mut ntoken: felt252 = 0;
            let total_number_of_tokens: felt252 = self.number_of_tokens.read();
            while ntoken != total_number_of_tokens {
                let token = self.map_tokens_to_tokenaddress.read(ntoken);
                let amount = self.map_users_deposited.read((user, token));
                let price = self.map_tokens_to_price.read(token);
                value += amount * price;
                ntoken += 1;
            };
            value
        }
        fn total_money_available_to_borrow(self: @ContractState, user: ContractAddress) -> u256 {
            // Suppose prices are up to date
            assert!(self.map_users_exists.read(user), "Please register first before using the app");
            let mut value: u256 = 0;
            let mut ntoken: felt252 = 0;
            let total_number_of_tokens: felt252 = self.number_of_tokens.read();
            while ntoken != total_number_of_tokens {
                let token = self.map_tokens_to_tokenaddress.read(ntoken);
                let amount = self.map_users_deposited.read((user, token));
                let amount = (amount * (volatility_scale - self.map_tokens_to_collateral_factor.read(token))) / volatility_scale;
                let price = self.map_tokens_to_price.read(token);
                value += amount * price;
                ntoken += 1;
            };
            value
        }
        fn total_money_borrowed(self: @ContractState, user: ContractAddress) -> u256 {
            // Suppose prices are up to date
            assert!(self.map_users_exists.read(user), "Please register first before using the app");
            let mut value: u256 = 0;
            let mut ntoken: felt252 = 0;
            let total_number_of_tokens: felt252 = self.number_of_tokens.read();
            while ntoken != total_number_of_tokens {
                let token = self.map_tokens_to_tokenaddress.read(ntoken);
                let amount = self.map_users_borrowed.read((user, token));
                let price = self.map_tokens_to_price.read(token);
                value += amount * price;
                ntoken += 1;
            };
            value
        }
        fn try_to_liquidate_everyone(ref self: ContractState) {
            assert(self.are_we_in_hook.read(), 'Internal'); // Price updated when this function is called
            let mut id_user: felt252 = 0;
            let latest_id: felt252 = self.next_id.read(); // This id doesn't exist yet, everything before exists
            while id_user != latest_id {
                let user = self.map_users_id.read(id_user);
                self.try_to_liq_user(user);
                id_user += 1;
            };
        }
        fn do_we_liq(ref self: ContractState, user: ContractAddress) -> bool {
            // Doesn't validate user
            let available = self.total_money_available_to_borrow(user);
            let borrowed  = self.total_money_borrowed(user);
            borrowed > available // Todo améliorer
        }
        // Internal
        fn try_to_liq_user(ref self: ContractState, user: ContractAddress) -> bool {
            assert(self.are_we_in_hook.read(), 'Internal'); // Price updated when this function is called
            let available = self.total_money_available_to_borrow(user);
            let borrowed  = self.total_money_borrowed(user);
            // Todo utiliser la fonction du dessus?
            // Mais on a besoin de borrowed et available - donc non
            let do_we_liq = borrowed > available;
            if do_we_liq {
                let mut token_to_use = self.map_users_token_to_use.read(user);
                let mut token_to_repay = self.map_users_token_to_repay.read(user);
                // Both are different by other asserts in the code
                // A bit too much, but enough
                let price_to_liquidate = borrowed - available; 
                let mut amount: u256 = price_to_liquidate / self.map_tokens_to_price.read(token_to_use);
                // If token to use is enough to liquidate, we skip this if
                // Otherwise, we go into to find another token_to_use to liquidate
                if amount.into() < self.map_users_deposited.read((user, token_to_use)) {
                    token_to_use = contract_address_const::<0>();
                    let mut token_default = contract_address_const::<0>(); // In case we find no token
                    // We check which token to use
                    let mut ntoken: felt252 = 0;
                    let total_number_of_tokens: felt252 = self.number_of_tokens.read();
                    while ntoken != total_number_of_tokens {
                        let token = self.map_tokens_to_tokenaddress.read(ntoken);
                        if token != token_to_repay {
                            let deposited_amount = self.map_users_deposited.read((user, token));
                            let deposited_price: u256 = deposited_amount.into() * self.map_tokens_to_price.read(token);
                            if (deposited_price >= price_to_liquidate) { // We can liquidate with that token
                                token_to_use = token;
                                amount = (deposited_amount * price_to_liquidate) / deposited_price;
                                break;
                            }
                            if (deposited_amount > 0) {
                                token_default = token; // To use when we don't find anything else
                            }
                        }
                        ntoken += 1;
                    };
                    // There might rare cases where no token are found, in that case we liquidate what we can this round
                    // and the next round will liquidate other positions
                    if token_to_use == contract_address_const::<0>() {
                        token_to_use = token_default;
                        // If the only token to use to repay in token_to_repay
                        if token_to_use == contract_address_const::<0>() {
                            token_to_use = token_to_repay;
                            amount = self.map_users_deposited.read((user, token_to_use)); // We liquidate the whole thing because there is not enough
                            // We now need to pick the token to repay - we just pick whatever we have debt in
                            let mut n_token: felt252 = 0;
                            let last_token = self.number_of_tokens.read();
                            while n_token != last_token {
                                let token = self.map_tokens_to_tokenaddress.read(n_token);
                                if (token != token_to_use) && (self.map_users_borrowed.read((user, token)) > 0) {
                                    token_to_repay = token;
                                    break;
                                }
                                n_token += 1;
                            }
                        }
                    }
                }
                // tant pis on liq quand même
                let token_to_use = IERC20Dispatcher { contract_address: token_to_use };
                let token_to_repay = IERC20Dispatcher { contract_address: token_to_repay };
                self.liquidate(user, token_to_use, token_to_repay, amount.try_into().unwrap());
            }
            do_we_liq
        }
        fn liquidate(ref self: ContractState,
                    user: ContractAddress,
                    token_from: IERC20Dispatcher,
                    token_to: IERC20Dispatcher,
                    amount: u128)
        {
            // Doesnt validate user, token_from, and token_to
            let router = self.ekuboRouter.read();
            // The protocol owns the tokens, so no transferFrom
            token_from.transfer(router.contract_address, amount.into());
            // Now we build the swap - token_amount is the datastructure taken by the router
            let token_amount = TokenAmount {
                token: token_from.contract_address,
                amount: i129 {
                    mag: amount,
                    sign: false
                }
            };
            // Ekubo requirement: the first pool is the one that has the lowest id
            let normal = token_from.contract_address <= token_to.contract_address;
            let token0 = (if normal { token_from } else { token_to }).contract_address;
            let token1 = (if normal { token_to } else { token_from }).contract_address;
            let sqrt_ratio_limit = if normal { min_sqrt_ratio_limit } else { max_sqrt_ratio_limit };
            let pool = PoolKey {
                token0, token1,
                fee: 170141183460469235273462165868118016,
                tick_spacing: 1000,
                extension: contract_address_const::<0x0>()
            };
            let route = RouteNode { pool_key: pool, sqrt_ratio_limit, skip_ahead: 0 };
            let mut result = router.swap(route, token_amount);
            // ??
            IClearDispatcher { contract_address: router.contract_address }.clear(token_from);
            IClearDispatcher { contract_address: router.contract_address }.clear(token_to);
            
            // Update the maps
            // It's as if we've withdraw a bit to pay a bit of debt + on some case debt becomes asset and the reverse
            // First, amount0
            let amount0 = result.amount0.mag.into();
            let old_deposited = self.map_users_deposited.read((user, token_from.contract_address));
            if amount0 > old_deposited {
                self.map_users_deposited.write((user, token_from.contract_address), 0);
                self.map_users_borrowed.write((user, token_from.contract_address), amount0 - old_deposited);
            } else {
                self.map_users_deposited.write((user, token_from.contract_address), old_deposited - amount0);
            }

            // Second, amount1
            let amount1 = result.amount1.mag.into();
            let old_debt = self.map_users_deposited.read((user, token_to.contract_address));
            // On some case we swapped too much and repaid too much, so we convert that into deposited assets
            if amount1 > old_debt {
                self.map_users_borrowed.write((user, token_to.contract_address), 0);
                self.map_users_deposited.write((user, token_to.contract_address), amount1 - old_debt);
            } else {
                self.map_users_deposited.write((user, token_to.contract_address), old_debt - amount1);
            };
            // Todo assert about the obtained amount to avoid being taken advantage of by sandwichers calling the function
        }
        fn update_all_token_price(ref self: ContractState) {
            let mut n_token: felt252 = 0;
            let last_token = self.number_of_tokens.read();
            let oracle = self.pragmaOracle.read();
            while n_token != last_token {
                let token = self.map_tokens_to_tokenaddress.read(n_token);
                let asset = DataType::SpotEntry(self.map_tokens_to_oraclekey.read(token));
                let price = oracle.get_data(asset, AggregationMode::Median(())).price;
                self.map_tokens_to_price.write(token, price.into());
                n_token += 1;
            }
        }

        // % of your amount per block - not APY
        // block time = 6min: 87600 block per year
        // 0.99995 ** 87600 = 0.012523987123685501
        // Therefore scale = 100000
        // >>> scale = 100000
        // >>> amount = 1
        // >>> (amount * (scale - 5))/scale
        // --> 0.99995
        fn supply_apy(self: @ContractState, token: IERC20Dispatcher) -> u256 {
            0
        }
        fn borrow_apy(self: @ContractState, token: IERC20Dispatcher) -> u256 {
            let deposited_amount = self.frontend_total_deposited_amount(token);
            let borrowed_amount = self.frontend_total_borrowed_amount(token);
            // If borrowed more than 90%
            if (borrowed_amount * 1000) / 900 > deposited_amount {
                return 8;
            }
            // If borrowed more than 50%
            if (borrowed_amount * 1000) / 500 > deposited_amount {
                return 5;
            }
            0
        }
        fn update_every_user_position(ref self: ContractState) {
            assert(self.are_we_in_hook.read(), 'Internal');
            let last_block = self.last_interaction_with_the_protocol.read();
            let current_block = get_block_number();
            let n: u256 = (current_block - last_block).into();
            if n > 0 {
                let mut id_user: felt252 = 0;
                let latest_id: felt252 = self.next_id.read();
                while id_user != latest_id {
                    let user = self.map_users_id.read(id_user);
                    self.update_user_position(user, n);
                    id_user += 1;
                };
                self.last_interaction_with_the_protocol.write(current_block);
            }
        }
        // Internal
        // Todo faire pour le supply apy aussi
        fn update_user_position(ref self: ContractState, user: ContractAddress, n: u256) {
            assert(self.are_we_in_hook.read(), 'Internal');
            let sself = @self; // lol
            let mut n_token: felt252 = 0;
            let last_token = self.number_of_tokens.read();
            while n_token != last_token {
                let token = self.map_tokens_to_tokenaddress.read(n_token);
                let debt = self.map_users_borrowed.read((user, token));
                let borrow_apy = sself.borrow_apy(IERC20Dispatcher { contract_address: token });
                let new_debt = (debt * (APY_SCALE + borrow_apy * n)) / APY_SCALE; // On approxime osef - todo regler ça quand même
                self.map_users_borrowed.write((user, token), new_debt);
                n_token += 1;
            };
        }

        fn frontend_get_number_of_users(self: @ContractState) -> u256 {
            self.next_id.read().into()
        }
        fn frontend_get_TLV(self: @ContractState) -> u256 {
            let mut total: u256 = 0;
            let mut n_token: felt252 = 0;
            let last_token = self.number_of_tokens.read();
            while n_token != last_token {
                let token = IERC20Dispatcher { contract_address: self.map_tokens_to_tokenaddress.read(n_token) };
                total += self.frontend_total_deposited_amount(token) - self.frontend_total_borrowed_amount(token);
                n_token += 1;
            };
            total
        }
        fn frontend_get_asset_price(self: @ContractState, token: IERC20Dispatcher) -> u256 {
            self.map_tokens_to_price.read(token.contract_address)
        }

        fn is_supported_token(self: @ContractState, token: IERC20Dispatcher) -> bool {
            let mut n_token: felt252 = 0;
            let last_token = self.number_of_tokens.read();
            let mut found = false;
            while n_token != last_token {
                if self.map_tokens_to_tokenaddress.read(n_token) == token.contract_address {
                    found = true;
                }
                n_token += 1;
            };
            found
        }

        fn hook(ref self: ContractState) {
            self.are_we_in_hook.write(true);
            self.update_all_token_price();
            self.update_every_user_position();
            self.try_to_liquidate_everyone();
            self.are_we_in_hook.write(false);
        }

        fn frontend_get_user_points(self: @ContractState, user: ContractAddress) -> u256 {
            self.map_users_points.read(user)
        }
        fn frontend_get_total_points(self: @ContractState) -> u256 {
            let mut total: u256 = 0;
            let mut n_user: felt252 = 0;
            let last_user = self.next_id.read();
            while n_user != last_user {
                let user = self.map_users_id.read(n_user);
                total += self.map_users_points.read(user);
                n_user += 1;
            };
            total
        }
        fn increase_user_points(ref self: ContractState, user: ContractAddress, points: u256) {} // Only admin
        fn set_user_points_to_0(ref self: ContractState, user: ContractAddress) {} // Only admin
        // Vampire campaign
        fn admin_create_new_points_campaign(self: @ContractState) {} // Only admin
        fn register_for_the_current_campaign(self: @ContractState) {} // Require a deposit
        fn admin_blacklist_user_campaign(self: @ContractState, user: ContractAddress) {} // Remove a lying user from the campaign
        fn admin_finish_point_campaign(ref self: ContractState, user: ContractAddress) {} // Todo args
        fn admin_dissalow_new_futur_points_campaign(self: @ContractState) {} // Only admin

        // Frontends
        fn frontend_deposited_amount(self: @ContractState, user: ContractAddress, token: IERC20Dispatcher) -> u256 {
            self.map_users_deposited.read((user, token.contract_address))
        }
        fn frontend_borrowed_amount(self: @ContractState, user: ContractAddress, token: IERC20Dispatcher) -> u256 {
            self.map_users_borrowed.read((user, token.contract_address))
        }
        fn frontend_total_deposited_amount(self: @ContractState, token: IERC20Dispatcher) -> u256 {
            let mut total: u256 = 0;
            let mut n_user: felt252 = 0;
            let last_user = self.next_id.read();
            while n_user != last_user {
                let user = self.map_users_id.read(n_user);
                total += self.map_users_deposited.read((user, token.contract_address));
                n_user += 1;
            };
            total
        }
        fn frontend_total_borrowed_amount(self: @ContractState, token: IERC20Dispatcher) -> u256 {
            let mut total: u256 = 0;
            let mut n_user: felt252 = 0;
            let last_user = self.next_id.read();
            while n_user != last_user {
                let user = self.map_users_id.read(n_user);
                total += self.map_users_borrowed.read((user, token.contract_address));
                n_user += 1;
            };
            total
        }
        fn frontend_utilisation_rate(self: @ContractState, user: ContractAddress) -> u256 {
            let total_deposited = self.total_money_deposited(user);
            let total_borrowed = self.total_money_borrowed(user);
            if total_deposited == 0 {
                return 0;
            }
            (total_borrowed * 100) / total_deposited
        }
        fn frontend_utilisation_rate_after_deposit(self: @ContractState, user: ContractAddress, token: IERC20Dispatcher, amount: u256) -> u256 {
            let total_deposited = self.total_money_deposited(user);
            let additional_deposit = amount * self.map_tokens_to_price.read(token.contract_address);
            let total_borrowed = self.total_money_borrowed(user);
            if total_deposited == 0 {
                return 0;
            }
            (total_borrowed * 100) / (total_deposited + additional_deposit)

        }
        fn frontend_utilisation_rate_after_borrow(self: @ContractState, user: ContractAddress, token: IERC20Dispatcher, amount: u256) -> u256 {
            let total_deposited = self.total_money_deposited(user);
            let total_borrowed = self.total_money_borrowed(user);
            let additional_borrow = amount * self.map_tokens_to_price.read(token.contract_address);
            if total_deposited == 0 {
                return 0;
            }
            ((total_borrowed + additional_borrow) * 100) / total_deposited
        }
        fn frontend_utilisation_rate_after_repay(self: @ContractState, user: ContractAddress, token: IERC20Dispatcher, amount: u256) -> u256 {
            let total_deposited = self.total_money_deposited(user);
            let total_borrowed = self.total_money_borrowed(user);
            let additional_repay = amount * self.map_tokens_to_price.read(token.contract_address);
            if total_deposited == 0 {
                return 0;
            }
            let answer = ((total_borrowed - additional_repay) * 100) / total_deposited;
            if answer < 0 {
                return 0;
            }
            answer
        }
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            assert!(get_caller_address() == contract_address_const::<0x07d25449d864087e8e1ddbd237576c699dfe0ea98979d920fcf84dbd92a49e10>(), "Only the admin can upgrade the contract");
            replace_class_syscall(new_class_hash).unwrap();
        }

        // fn set_price(ref self: ContractState, token: ContractAddress, value: u256) {
        //     self.map_tokens_to_price.write(token, value);
        // }
        // fn liquidate_single_user(ref self: ContractState, user: ContractAddress) {
        //     self.are_we_in_hook.write(true);
        //     self.try_to_liq_user(user);
        //     self.are_we_in_hook.write(false);
        // }
    }
}