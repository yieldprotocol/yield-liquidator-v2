use ethers::prelude::*;
use yield_liquidator::{escalator::GeometricGasPrice, keeper::Keeper};

use gumdrop::Options;
use serde::Deserialize;
use std::{convert::TryFrom, path::PathBuf, sync::Arc, time::Duration};
use tracing::info;
use tracing_subscriber::{filter::EnvFilter, fmt::Subscriber};

// CLI Options
#[derive(Debug, Options, Clone)]
struct Opts {
    help: bool,

    #[options(help = "path to json file with the contract addresses")]
    config: PathBuf,

    #[options(
        help = "the Ethereum node endpoint (HTTP or WS)",
        default = "http://localhost:8545"
    )]
    url: String,

    #[options(help = "chain id", default = "1")]
    chain_id: u64,

    #[options(help = "path to your private key")]
    private_key: PathBuf,

    #[options(help = "polling interval (ms)", default = "1000")]
    interval: u64,

    #[options(help = "Multicall batch size", default = "1000")]
    multicall_batch_size: usize,

    #[options(help = "the file to be used for persistence", default = "data.json")]
    file: PathBuf,

    #[options(help = "the minimum ratio (collateral/debt) to trigger liquidation, percents", default = "110")]
    min_ratio: u16,

    #[options(help = "extra gas to use for transactions, percent of estimated gas", default = "10")]
    gas_boost: u16,

    #[options(help = "Don't bump gas until the transaction is this many seconds old", default = "90")]
    bump_gas_delay: u64,

    #[options(help = "the block to start watching from")]
    start_block: Option<u64>,

    #[options(default="false", help="Use JSON as log format")]
    json_log: bool,

    #[options(default="false", help="Only run 1 iteration and exit")]
    one_shot: bool,

    #[options(
        help = "Instance name (used for logging)",
        default = "undefined"
    )]
    instance_name: String,
}

#[derive(Deserialize)]
struct Config {
    #[serde(rename = "Witch")]
    witch: Address,
    #[serde(rename = "Flash")]
    flashloan: Address,
    #[serde(rename = "Multicall2")]
    multicall2: Address,
}

fn init_logger(use_json: bool) {
    let sub_builder = 
        Subscriber::builder()
        .with_env_filter(EnvFilter::from_default_env());

    if use_json {
        sub_builder
            .json()
            .with_current_span(true)
            .with_span_list(true)
            .init();
    } else {
        sub_builder
            .init();
    }
}

async fn main_impl() -> anyhow::Result<()> {
    let opts = Opts::parse_args_default_or_exit();

    init_logger(opts.json_log);


    if opts.url.starts_with("http") {
        let provider = Provider::<Http>::try_from(opts.url.clone())?;
        run(opts, provider).await?;
    } else {
        let ws = Ws::connect(opts.url.clone()).await?;
        let provider = Provider::new(ws);
        run(opts, provider).await?;
    }

    Ok(())
}

#[tokio::main]
async fn main() {
    match main_impl().await {
        Ok(_) => {
            std::process::exit(exitcode::OK);
        }
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(exitcode::DATAERR);
        }
    };
}

async fn run<P: JsonRpcClient + 'static>(opts: Opts, provider: Provider<P>) -> anyhow::Result<()> {
    info!("Starting Yield-v2 Liquidator.");
    let provider = provider.interval(Duration::from_millis(opts.interval));
    let private_key = std::fs::read_to_string(opts.private_key)?.trim().to_string();
    let wallet: LocalWallet = private_key.parse()?;
    let wallet = wallet.with_chain_id(opts.chain_id);
    let address = wallet.address();
    let client = SignerMiddleware::new(provider, wallet);
    let client = NonceManagerMiddleware::new(client, address);
    let client = Arc::new(client);
    info!("Profits will be sent to {:?}", address);

    info!(instance_name=opts.instance_name.as_str(), "Node: {}", opts.url);

    let cfg: Config = serde_json::from_reader(std::fs::File::open(opts.config)?)?;
    info!("Witch: {:?}", cfg.witch);
    info!("Multicall2: {:?}", cfg.multicall2);
    info!("FlashLiquidator {:?}", cfg.flashloan);
    info!("Persistent data will be stored at: {:?}", opts.file);

    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .open(&opts.file)
        .unwrap();
    let state = serde_json::from_reader(&file).unwrap_or_default();

    let mut gas_escalator = GeometricGasPrice::new();
    gas_escalator.coefficient = 1.12501;
    gas_escalator.every_secs = 5; // TODO: Make this be 90s
    gas_escalator.max_price = Some(U256::from(5000 * 1e9 as u64)); // 5k gwei

    let mut keeper = Keeper::new(
        client,
        cfg.witch,
        cfg.flashloan,
        cfg.multicall2,
        opts.multicall_batch_size,
        opts.min_ratio,
        opts.gas_boost,
        gas_escalator,
        opts.bump_gas_delay,
        state,
        format!("{}.witch={:?}.flash={:?}", opts.instance_name, cfg.witch, cfg.flashloan)
    ).await?;

    if opts.one_shot {
        keeper.one_shot().await?;
    } else {
        keeper.run(opts.file, opts.start_block).await?;
    }

    Ok(())
}
