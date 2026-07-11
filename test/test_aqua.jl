# Aqua quality checks (plan: the qa-workflow analogue of ruff/ty).
import Aqua

@testset "Aqua" begin
    Aqua.test_all(Bonnie)
end
