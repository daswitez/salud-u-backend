package bo.edu.uagrm.saludu.scheduling.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.scheduling.application.BlockProposal;
import bo.edu.uagrm.saludu.scheduling.application.BlockProposalService;
import com.fasterxml.jackson.databind.JsonNode;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.format.DateTimeParseException;
import java.util.Set;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** O-07 / UC-31: bloqueo de una jornada con citas, reprogramándolas antes. El bloqueo del médico no cambia. */
@RestController
@RequestMapping("/api/scheduling/block-proposals")
@PreAuthorize("hasRole('ADMINISTRATIVE')")
public class BlockProposalController {
    private static final Set<String> FIELDS = Set.of("staffId", "date", "startTime", "endTime", "label");
    private final BlockProposalService proposals;

    public BlockProposalController(BlockProposalService proposals) { this.proposals = proposals; }

    /** {"staffId", "date": AAAA-MM-DD, "startTime"/"endTime": HH:MM (ambos o ninguno = día completo), "label"}. */
    @PostMapping
    public ResponseEntity<LegacyAvailabilityResponse<BlockProposal>> propose(@RequestBody JsonNode body, @AuthenticationPrincipal SessionPrincipal principal) {
        if (body == null || !body.isObject() || !body.path("staffId").isTextual() || !body.path("date").isTextual() || !body.path("label").isTextual())
            throw invalid();
        for (var names = body.fieldNames(); names.hasNext(); ) if (!FIELDS.contains(names.next())) throw invalid();
        UUID staffId;
        LocalDate date;
        try {
            staffId = UUID.fromString(body.path("staffId").textValue());
            date = LocalDate.parse(body.path("date").textValue());
        } catch (IllegalArgumentException | DateTimeParseException exception) { throw invalid(); }
        BlockProposal proposal = proposals.propose(principal, staffId, date, time(body.path("startTime")), time(body.path("endTime")), body.path("label").textValue());
        return response(201, proposal);
    }

    @GetMapping("/{id}")
    public ResponseEntity<LegacyAvailabilityResponse<BlockProposal>> get(@PathVariable UUID id, @AuthenticationPrincipal SessionPrincipal principal) {
        return response(200, proposals.get(principal, id));
    }

    @PostMapping("/{id}/apply")
    public ResponseEntity<LegacyAvailabilityResponse<BlockProposal>> apply(@PathVariable UUID id, @AuthenticationPrincipal SessionPrincipal principal) {
        return response(200, proposals.applyBlock(principal, id));
    }

    private static LocalTime time(JsonNode node) {
        if (node.isMissingNode() || node.isNull()) return null;
        if (!node.isTextual() || !node.textValue().matches("\\d{2}:\\d{2}")) throw invalid();
        try { return LocalTime.parse(node.textValue()); } catch (DateTimeParseException exception) { throw invalid(); }
    }

    private static AvailabilityException invalid() {
        return new AvailabilityException(400, "Indica el médico, la fecha (AAAA-MM-DD), el nombre del bloqueo y, si no es el día completo, las horas HH:MM.");
    }

    private static <T> ResponseEntity<LegacyAvailabilityResponse<T>> response(int status, T data) {
        return ResponseEntity.status(status).header("Cache-Control", "no-store, private").body(LegacyAvailabilityResponse.success(data));
    }
}
