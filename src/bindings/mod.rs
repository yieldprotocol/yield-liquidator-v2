mod cauldron;
pub use cauldron::*;

mod witch;
pub use witch::*;

mod flashliquidator;
pub use flashliquidator::*;

mod imulticall2;
pub use imulticall2::*;
pub use imulticall2::ResultData as IMulticall2Result;
pub use imulticall2::CallData as IMulticall2Call;

pub type VaultIdType = [u8; 12];
pub type ArtIdType = [u8; 6];
pub type InkIdType = [u8; 6];
pub type SeriesIdType = [u8; 6];