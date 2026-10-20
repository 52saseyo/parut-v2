package com.parut.order.settlement.presentation.dto.request;

import java.time.Instant;
import java.util.UUID;

import jakarta.validation.constraints.NotNull;

public record CompleteSettlementPerfRequest(@NotNull Instant cutoff, @NotNull UUID sellerId) {
}
